#lang racket/base

;; LZF decompressor, bit-compatible with liblzf (lzf_d.c in the Redis tree).
;;
;; Unlike the C decoder, which requires a correctly sized output buffer and
;; fails with E2BIG otherwise, this decoder grows its output buffer
;; automatically: each token first ensures enough room, doubling the buffer
;; (starting from the caller's `#:hint`) when needed. Truncated input and
;; back-references reaching before the start of the output raise `exn:fail`
;; (the C decoder reports EINVAL for both when CHECK_INPUT is enabled).

(provide lzf-decompress)

(require lzf/private/format)

;; Decodes a liblzf stream. Returns a freshly allocated exact-size byte
;; string. The empty byte string decodes to the empty byte string.
(define (lzf-decompress bs #:hint [hint #f])
  (define n (bytes-length bs))
  (define cap (or hint (max 64 (* 4 n))))
  (define out (make-bytes cap))
  (define op 0)   ; bytes written to `out`
  (define ip 0)   ; bytes read from `bs`

  (define (grow! need)
    (when (> need cap)
      (let grow ([c (max 64 (* 2 cap))])
        (if (>= c need) (set! cap c) (grow (* 2 c))))
      (define nb (make-bytes cap))
      (bytes-copy! nb 0 out 0 op)
      (set! out nb)))

  (let continue ()
    (when (< ip n)
      (define ctrl (bytes-ref bs ip))
      (set! ip (add1 ip))
      (cond
        ;; 000LLLLL <L+1> : literal run of ctrl+1 raw bytes
        [(< ctrl 32)
         (define len (add1 ctrl))
         (when (> (+ ip len) n)
           (error 'lzf-decompress
                  "corrupt LZF stream: truncated literal run (claims ~a bytes at offset ~a, only ~a left)"
                  len (- ip 1) (- n ip)))
         (grow! (+ op len))
         (bytes-copy! out op bs ip (+ ip len))
         (set! op (+ op len))
         (set! ip (+ ip len))]
        ;; LLLooooo [LLLLLLLL] oooooooo : back reference. Stream order after
        ;; the control byte: the extra length byte first (when len3 = 7),
        ;; then the offset low byte -- see lzf_d.c "if (len == 7) { len +=
        ;; *ip++; } ref -= *ip++;".
        [else
         (define hi (bitwise-and ctrl #x1F))
         (define len3 (arithmetic-shift ctrl -5))
         (define len
           (cond
             [(= len3 7)
              (when (>= ip n)
                (error 'lzf-decompress
                       "corrupt LZF stream: truncated back-reference (missing length byte at end of input)"))
              (define extra (bytes-ref bs ip))
              (set! ip (add1 ip))
              (+ 7 extra)]
             [else len3]))
         (when (>= ip n)
           (error 'lzf-decompress
                  "corrupt LZF stream: truncated back-reference (missing offset byte at end of input)"))
         (define lo (bytes-ref bs ip))
         (set! ip (add1 ip))
         (define copy-len (+ len 2))       ; C: op + len + 2 > out_end check
         (define off (+ (* hi 256) lo 1))  ; distance back; ref = op - off
         (define ref (- op off))
         (when (negative? ref)
           (error 'lzf-decompress
                  "corrupt LZF stream: back-reference reaches before start of output (offset ~a at output position ~a)"
                  off op))
         (grow! (+ op copy-len))
         (cond
           ;; C: op >= ref + len -> disjunct areas, bulk copy.
           [(<= (+ ref copy-len) op)
            (bytes-copy! out op out ref (+ ref copy-len))]
           ;; Overlapping (RLE-style) copy, byte by byte.
           [else
            (let cp ([s ref] [d op] [k copy-len])
              (when (> k 0)
                (bytes-set! out d (bytes-ref out s))
                (cp (add1 s) (add1 d) (sub1 k))))])
         (set! op (+ op copy-len))])
      (continue)))
  (subbytes out 0 op))
