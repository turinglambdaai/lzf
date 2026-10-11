#lang racket/base

;; Format constants shared by the LZF encoder and decoder.
;;
;; These mirror the reference C implementation (lzf_c.c / lzfP.h in the
;; Redis tree, by Marc Alexander Lehmann):
;;
;;   MAX_LIT (1 << 5)             longest literal run
;;   MAX_OFF (1 << 13)            maximum back-reference distance
;;   MAX_REF ((1 << 8) + (1 << 3)) maximum match length
;;
;; HLOG selects liblzf's low-memory hash configuration (13), as specified
;; for this package. The compressed *format* is independent of HLOG, so the
;; choice affects compression ratio only.

(provide max-lit
         max-off
         max-ref
         hlog
         hsize
         mask32)

(define max-lit 32)                    ; (1 << 5)
(define max-off 8192)                  ; (1 << 13)
(define max-ref 264)                   ; (1 << 8) + (1 << 3)

(define hlog 13)
(define hsize (arithmetic-shift 1 hlog)) ; 8192 single slots

;; C `unsigned int` wraparound, needed to reproduce liblzf's rolling hash
;; arithmetic exactly.
(define (mask32 x) (bitwise-and #xFFFFFFFF x))
