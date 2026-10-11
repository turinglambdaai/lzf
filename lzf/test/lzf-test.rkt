#lang racket/base

;; Tests for the lzf package: hand-constructed golden liblzf buffers,
;; round trips, hint handling, corrupt input, determinism, and a
;; performance sanity check.
;;
;; Golden buffers are built byte-by-byte against the reference decoder
;; lzf_d.c (Redis tree, Marc Alexander Lehmann), and the encoder pin is
;; derived from lzf_c.c.

(require rackunit
         racket/file
         racket/format
         racket/runtime-path
         lzf)

;; ---------- helpers ----------

(define (repeat-bytes bs k)
  (define len (bytes-length bs))
  (define out (make-bytes (* len k)))
  (for ([i (in-range k)])
    (bytes-copy! out (* i len) bs 0 len))
  out)

;; repeat `bs` until it spans at least `target` bytes
(define (repeat-to-size bs target)
  (repeat-bytes bs (max 1 (ceiling (/ target (bytes-length bs))))))

(random-seed 20261011) ; deterministic pseudo-random corpus
(define (random-bytes len)
  (define bs (make-bytes len))
  (for ([i (in-range len)])
    (bytes-set! bs i (random 256)))
  bs)

(define-runtime-path test-dir ".")
(define package-root (simplify-path (build-path test-dir 'up 'up)))
(define readme (file->bytes (build-path package-root "README.md")))

(define (check-round-trip name bs)
  (check-equal? (lzf-decompress (lzf-compress bs)) bs (format "round trip: ~a" name)))

;; ---------- 1. golden buffers, justified against lzf_d.c ----------

;; Literal run. lzf_d.c: "if (ctrl < (1 << 5)) /* literal run */ { ctrl++;
;; ... }" -- control byte 0x04 announces 4 + 1 = 5 literal bytes.
(check-equal? (lzf-decompress #"\x04Hello") #"Hello")

;; One-byte literal run (0x00 -> 1 literal).
(check-equal? (lzf-decompress #"\x00Z") #"Z")

;; Back reference with length < 7, overlapping (RLE). Decoding of 0x60:
;; len3 = 0x60 >> 5 = 3, hi = 0x60 & 0x1f = 0, so per lzf_d.c
;; "ref = op - ((ctrl & 0x1f) << 8) - 1" = 1 - 0 - 1 = 0, then "ref -= *ip++"
;; with lo = 0x00 keeps ref = 0; len += 2 -> copy 5 bytes from position 0
;; through the overlapping byte-by-byte path. Preceded by one literal 'a'
;; (ctrl 0x00). Result: "aaaaaa".
(check-equal? (lzf-decompress #"\x00a\x60\x00") #"aaaaaa")

;; Back reference with length < 7, non-overlapping. 0x02: three literals
;; "abc". 0x20: len3 = 1 (copy 1 + 2 = 3 bytes), lo = 0x02 -> distance
;; (0 << 8) + 2 + 1 = 3, ref = 3 - 3 = 0. Result: "abcabc".
(check-equal? (lzf-decompress #"\x02abc\x20\x02") #"abcabc")

;; Extended-length back reference (len >= 7): 20 zero bytes. 0x00: one
;; literal 0x00. 0xE0: len3 = 7 -> lzf_d.c "if (len == 7) { len += *ip++; }"
;; with extra byte 0x0a -> len = 17, so copy 17 + 2 = 19 bytes; offset byte
;; 0x00 -> distance 1, ref = 1 - 1 = 0. Overlapping copy fills 20 zeros.
(check-equal? (lzf-decompress #"\x00\x00\xe0\x0a\x00") (make-bytes 20 0))

;; Literal-run cap: MAX_LIT = (1 << 5) = 32, so 40 literal bytes need two
;; runs -- ctrl 0x1f (31 -> 32 bytes) then ctrl 0x07 (7 -> 8 bytes).
(check-equal? (lzf-decompress (bytes-append #"\x1f" (make-bytes 32 65)
                                            #"\x07" (make-bytes 8 66)))
              (bytes-append (make-bytes 32 65) (make-bytes 8 66)))

;; Encoder pin: exact tokenizer output for "aaaaaa", derived from lzf_c.c.
;; Position 0 is never a back-reference candidate (C: "ref > (u8 *)in_data"),
;; so bytes 0-1 form a two-byte literal run (ctrl 0x01), bytes 2-4 a length-3
;; match at distance 1 (ctrl 0x20 = (1 << 5) | 0 >> 8, offset byte 0x00), and
;; byte 5 a trailing one-byte literal run (ctrl 0x00, 'a').
(check-equal? (lzf-compress #"aaaaaa") #"\x01aa\x20\x00\x00a")

;; ---------- 2. round trips ----------

(check-equal? (lzf-compress #"") #"" "empty compresses to empty")
(check-equal? (lzf-decompress #"") #"" "empty decompresses to empty")

(check-round-trip "1 byte" #"Q")
(check-round-trip "2 bytes" #"QK")
(check-round-trip "3 identical bytes" (make-bytes 3 7))
(check-round-trip "1 KiB pseudo-random (incompressible)" (random-bytes 1024))
(check-round-trip "1 MiB repeating pattern"
                  (repeat-to-size #"The quick brown fox jumps over the lazy dog. "
                                  (* 1024 1024)))
(check-round-trip "100 KiB all zeros" (make-bytes (* 100 1024) 0))
(check-round-trip "README (real text)" readme)
(check-round-trip "~300 KiB real text (README corpus)"
                  (repeat-to-size readme (* 300 1024)))

;; Determinism: the same input always yields the same output bytes.
(check-equal? (lzf-compress readme) (lzf-compress readme))

;; ---------- 3. hint handling ----------

;; A hint far below the true output size must still decode correctly.
(check-equal? (lzf-decompress (lzf-compress readme) #:hint 1) readme)

;; Hint 0 (allowed by the contract) grows from nothing.
(check-equal? (lzf-decompress (lzf-compress (make-bytes (* 100 1024) 0)) #:hint 0)
              (make-bytes (* 100 1024) 0))

;; An exact hint works too.
(check-equal? (lzf-decompress (lzf-compress readme) #:hint (bytes-length readme))
              readme)

;; ---------- 4. corrupt input ----------

;; Back reference reaching before the start of output: no output yet, ctrl
;; 0x20 with offset byte 0x05 asks for distance (0 << 8) + 5 + 1 = 6, so
;; ref = 0 - 6 = -6. lzf_d.c: "if (ref < (u8 *)out_data) { SET_ERRNO
;; (EINVAL); return 0; }" -- we raise exn:fail instead of crashing.
(check-exn exn:fail? (λ () (lzf-decompress #"\x20\x05")))

;; Literal run claims 6 bytes, input has only 2 (lzf_d.c CHECK_INPUT: EINVAL).
(check-exn exn:fail? (λ () (lzf-decompress #"\x05ab")))

;; Truncated back reference: missing offset byte.
(check-exn exn:fail? (λ () (lzf-decompress #"\x20")))

;; Truncated long back reference: length byte present, offset byte missing.
(check-exn exn:fail? (λ () (lzf-decompress #"\xe0\x0a")))

;; Truncated long back reference: missing length byte.
(check-exn exn:fail? (λ () (lzf-decompress #"\xe0")))

;; Corrupt-input errors are exn:fail (not contract errors, not segfaults),
;; including for randomized control bytes with no room to seek back.
(check-exn exn:fail? (λ () (lzf-decompress (bytes 223 (random 256)))))

;; ---------- 5. performance sanity (not a benchmark) ----------

;; Compressing ~1 MiB of text must complete well under 5 seconds on
;; Racket CS. Uses bytes primitives: one preallocated output buffer,
;; bytes-copy! for bulk moves, no per-byte bytes-append.
(define perf-corpus (repeat-to-size readme (* 1024 1024)))
(define t0 (current-inexact-milliseconds))
(define compressed (lzf-compress perf-corpus))
(define t1 (current-inexact-milliseconds))
(define roundtrip-ok (bytes=? (lzf-decompress compressed) perf-corpus))
(define t2 (current-inexact-milliseconds))
(displayln
 (format "perf: ~a bytes -> ~a bytes | compress ~a ms, decompress ~a ms"
         (bytes-length perf-corpus)
         (bytes-length compressed)
         (real->decimal-string (- t1 t0) 1)
         (real->decimal-string (- t2 t1) 1)))
(check-true roundtrip-ok "perf corpus round trip")
(check-true (< (- t1 t0) 5000.0) "compression completes under 5 s")
