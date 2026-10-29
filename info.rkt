#lang info

(define version "0.1")
;; Multi-collection package shape: the collection is the `lzf/` subdirectory.
;; `collection 'multi` is the standard declaration for this layout — omitting
;; the field (or naming a collection) would make raco pkg treat the package
;; root itself as a single collection.
(define collection 'multi)
;; rackunit-lib is a run-time dependency here (not merely a build-time one)
;; because the package ships its test suite, and the catalog's dependency
;; check scans shipped modules in run mode.
(define deps '("base" "rackunit-lib"))
(define build-deps '("base" "scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc "Pure-Racket implementation of the liblzf (LZF) compression format used by Redis RDB files and python-lzf")
(define pkg-authors '("turlamai"))
(define license 'MIT)
;; Loading the scribblings as a "test" produces no tests and noise; skip it.
(define test-omit-paths '("lzf/scribblings"))
