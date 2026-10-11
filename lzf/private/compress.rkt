#lang racket/base

;; Greedy LZF compressor, bit-compatible with liblzf (lzf_c.c in the Redis
;; tree). Configuration mirrors liblzf's default build:
;;
;;   - greedy longest-match extension (lzf_c.c lines 188-229),
;;   - single-slot hash table, one candidate per bucket,
;;   - `VERY_FAST`-style post-match insertion (two hash slots per match),
;;   - candidate rejected unless `ref > in_data` (position 0 is never
;;     referenced, exactly as in the C encoder),
;;   - hash table zero-initialized, making output deterministic (liblzf's
;;     default INIT_HTAB=0 leaves the table uninitialized).
;;
;; The table has HSIZE = 2^13 slots (HLOG 13). Hash parameters change
;; compression ratio only, never the emitted format.

(provide lzf-compress)

(require lzf/private/format)

(define (lzf-compress in)
  (define n (bytes-length in))
  (cond
    [(zero? n) #""]
    [else
     (define ht (make-vector hsize -1))
     ;; Worst case output: all literals => n bytes + one control byte per
     ;; 32-byte run, plus slack. Grows on demand anyway.
     (define out (make-bytes (+ n (quotient n 31) 2)))
     (define cap (bytes-length out))
     (define op 1)     ; control byte of the first literal run is reserved
     (define lit 0)    ; number of pending literal bytes in the current run

     (define (ensure-room! need)
       (when (> need cap)
         (let grow ([c (* 2 cap)])
           (if (>= c need) (set! cap c) (grow (* 2 c))))
         (define nb (make-bytes cap))
         (bytes-copy! nb 0 out 0 op)
         (set! out nb)))

     ;; C: op [- lit - 1] = lit - 1; op -= !lit;
     ;; Flushes the pending literal run; undoes the reserved control-byte
     ;; slot when the run is empty.
     (define (stop-run!)
       (cond
         [(zero? lit) (set! op (sub1 op))]
         [else (bytes-set! out (- op lit 1) (sub1 lit))]))

     (define main-limit (- n 2))

     ;; C lines 297-312: copy remaining (< 3) literal bytes, close the run.
     (define (finish-tail i)
       (ensure-room! (+ op 3))         ; C: at most 3 bytes can be missing here
       (let tl ([i i])
         (when (< i n)
           (ensure-room! (+ op 1))
           (set! lit (add1 lit))
           (bytes-set! out op (bytes-ref in i))
           (set! op (add1 op))
           (when (= lit max-lit)
             (bytes-set! out (- op lit 1) (sub1 lit)) ; stop run
             (set! lit 0)
             (set! op (add1 op)))                      ; start run
           (tl (add1 i))))
       (stop-run!)                     ; end run
       (subbytes out 0 op))

     ;; C lines 231-246. `elen` is the C `len` after `len -= 2`.
     (define (emit-match! i slot mlen)
       (define off (- i slot 1))
       (define elen (- mlen 2))
       (ensure-room! (+ op 4))         ; stop-run! may free one byte, ctrl+[extra+]low needs three
       (stop-run!)
       (define hi (arithmetic-shift off -8))
       (cond
         [(< elen 7)
          (bytes-set! out op (bitwise-ior hi (arithmetic-shift elen 5)))
          (set! op (add1 op))]
         [else
          (bytes-set! out op (bitwise-ior hi (arithmetic-shift 7 5)))
          (bytes-set! out (add1 op) (- elen 7))
          (set! op (+ op 2))])
       (bytes-set! out op (bitwise-and off #xFF))
       (set! op (add1 op))
       (set! lit 0)
       (set! op (add1 op)))            ; start run

     ;; Exact port of the match-extension loop (lzf_c.c lines 188-229).
     ;; Bytes at offsets 0, 1, 2 are already verified equal by the caller.
     ;; `maxlen` is the C `maxlen = min(MAX_REF, in_end - ip - 2)`; it bounds
     ;; the do/while phase, while the 16 unrolled checks may overshoot it by
     ;; one, exactly as in C.
     (define (extend-match ref i maxlen)
       (let unroll ([len 2] [k 16])
         (cond
           [(and (> maxlen 16) (> k 0))
            (define len2 (add1 len))
            (cond
              [(= (bytes-ref in (+ ref len2)) (bytes-ref in (+ i len2)))
               (unroll len2 (sub1 k))]
              [else len2])]
           [else
            (let step ([len len])
              (define len2 (add1 len))
              (cond
                [(and (< len2 maxlen)
                      (= (bytes-ref in (+ ref len2)) (bytes-ref in (+ i len2))))
                 (step len2)]
                [else len2]))])))

     ;; 24-bit hash window: the three input bytes starting at p.
     (define (window24 p)
       (+ (* (bytes-ref in p) 65536)
          (* (bytes-ref in (add1 p)) 256)
          (bytes-ref in (+ p 2))))

     ;; liblzf default (VERY_FAST) bucket index:
     ;;   IDX(h) = ((h >> (3*8 - HLOG)) - h*5) & (HSIZE - 1)
     (define (idx-of h)
       (bitwise-and (sub1 hsize)
                    (- (arithmetic-shift h (- 24 hlog)) (* h 5))))

     ;; Main loop. `hval` threads liblzf's rolling hash: at the top of each
     ;; iteration it is C's `hval` before the loop-top `NEXT`.
     (let main-loop ([i 0]
                     [hval (if (>= n 2)
                               (+ (* (bytes-ref in 0) 256)   ; FRST
                                  (bytes-ref in 1))
                               0)])
       (cond
         [(< i main-limit)
          (define h (mask32 (+ (* hval 256) (bytes-ref in (+ i 2))))) ; NEXT
          (define slot-idx (idx-of h))
          (define slot (vector-ref ht slot-idx))
          (vector-set! ht slot-idx i)
          (define mlen
            (and (>= slot 1)                    ; C: ref > in_data
                 (let ([off (- i slot 1)])
                   (and (< off max-off)
                        (= (bytes-ref in (+ slot 2)) (bytes-ref in (+ i 2)))
                        (= (bytes-ref in slot) (bytes-ref in i))
                        (= (bytes-ref in (add1 slot)) (bytes-ref in (add1 i)))
                        (extend-match slot i (min max-ref (- n i 2)))))))
          (cond
            [mlen
             (emit-match! i slot mlen)
             (define j (+ i mlen))
             (cond
               [(>= j main-limit) (finish-tail j)]
               [else
                ;; VERY_FAST post-match insertion (lzf_c.c lines 253-268):
                ;; record the last two windows covered by the match.
                (define p1 (- j 2))
                (define h1 (window24 p1))
                (vector-set! ht (idx-of h1) p1)
                (define h2 (mask32 (+ (* h1 256) (bytes-ref in (add1 j)))))
                (vector-set! ht (idx-of h2) (sub1 j))
                (main-loop j h2)])]
            [else
             ;; one more literal byte
             (ensure-room! (add1 op))
             (set! lit (add1 lit))
             (bytes-set! out op (bytes-ref in i))
             (set! op (add1 op))
             (when (= lit max-lit)
               (bytes-set! out (- op lit 1) (sub1 lit)) ; stop run
               (set! lit 0)
               (set! op (add1 op)))                     ; start run
             (main-loop (add1 i) h)])]
         [else (finish-tail i)]))]))
