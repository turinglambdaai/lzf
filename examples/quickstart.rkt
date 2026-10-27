#lang racket/base
;; Executable, transport-free example of the public LZF codec.
(require lzf)

(define sample
  (bytes-append (make-bytes 40 65) #" -- repeatable text -- repeatable text"))
(define encoded (lzf-compress sample))

(unless (bytes=? (lzf-decompress encoded) sample)
  (error 'lzf-quickstart "round-trip changed the payload"))
(unless (bytes=? (lzf-decompress encoded #:hint 0) sample)
  (error 'lzf-quickstart "decoder failed to grow a zero-sized hint"))
(unless (bytes=? encoded (lzf-compress sample))
  (error 'lzf-quickstart "identical input produced different bytes"))
(unless (and (bytes=? (lzf-compress #"") #"")
             (bytes=? (lzf-decompress #"") #""))
  (error 'lzf-quickstart "empty bytes special case failed"))

(displayln "LZF quickstart OK")
