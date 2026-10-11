#lang racket/base

;; Public API of the `lzf` collection: a pure-Racket codec for the liblzf
;; (LZF) compression format. Untyped core in lzf/private, contracts here at
;; the boundary.

(require racket/contract/base
         lzf/private/compress
         lzf/private/decompress)

;; Not provided by racket/base in this distribution; keep the dependency
;; footprint of the boundary module minimal by defining it here.
(define (natural? v) (and (exact-integer? v) (not (negative? v))))

(provide
 (contract-out
  [lzf-compress (-> bytes? bytes?)]
  [lzf-decompress (->* (bytes?) (#:hint natural?) bytes?)]))
