#lang scribble/manual

@(require (for-label lzf racket/base)
          scribble/eval)

@(define lzf-eval (make-base-eval #:lang 'racket/base))
@(interaction-eval #:eval lzf-eval (require lzf))

@title[#:tag "lzf"]{LZF: Pure-Racket LZF Compression}
@defmodule[lzf]

@margin-note{This package is a codec for the liblzf byte format, not a
binding to the C library: no FFI is used and no system liblzf installation
is required.}

The LZF format is a lightweight, byte-oriented LZ77 variant designed by Marc
Alexander Lehmann for his
@hyperlink["https://software.schmorp.de/pkg/liblzf.html"]{liblzf} library.
Its simplicity---@emph{one control byte per token, byte-granular copies, no
bit-planes}---makes it extremely fast in C, which is why it is the
string-compression codec embedded in
@hyperlink["https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/"]{Redis
RDB} persistence files and the interchange format of Python's
@tt{python-lzf} module.

This package implements the format in pure Racket, written against the
reference C sources in the Redis repository (@tt{src/lzf_c.c} and
@tt{src/lzf_d.c}):

@itemlist[
 @item{@racket[lzf-decompress] reads streams produced by liblzf, including
  payloads found in Redis RDB files and @tt{python-lzf} output;}
 @item{@racket[lzf-compress] produces streams decodable by liblzf.}
]

The wire format, for reference (from the comment in @tt{lzf_c.c}):

@(begin
   (verbatim
    "000LLLLL <L+1>              ; literal run, L+1 = 1..33 octets"
    "LLLooooo oooooooo           ; back reference, L+2 octets, offset o+1"
    "111ooooo LLLLLLLL oooooooo  ; back reference, L+9 octets, offset o+1"))

@section[#:tag "lzf-api"]{API}

@defproc[(lzf-compress [bs bytes?]) bytes?]{

 Compresses @racket[bs] with a greedy encoder and returns a liblzf-format
 byte string.

 The encoder uses a single-slot hash table of @tt{2^13} slots (liblzf's
 low-memory configuration, @tt{HLOG} = 13) with liblzf's default
 (@tt{VERY_FAST}) post-match insertion policy, and it never emits a back
 reference into position 0, exactly like the C encoder. The output is
 deterministic: the same input always produces the same bytes.

 Back references span at most @tt{2^13} bytes of distance and copy at
 most 264 bytes; literal runs hold at most 33 bytes. Compressing the empty
 byte string returns the empty byte string.
}

@defproc[(lzf-decompress [bs bytes?]
                         [#:hint hint natural?
                          (max 64 (* 4 (bytes-length bs)))]) bytes?]{

 Decompresses the liblzf stream @racket[bs] and returns a freshly allocated,
 exact-size byte string.

 @racket[hint] is an initial guess at the output size. Unlike the C
 decoder---which fails with @tt{E2BIG} when the caller's buffer is too
 small---this decoder grows its output buffer automatically whenever the
 hint is too small, so every valid stream decodes successfully regardless of
 the hint. Supplying an accurate hint merely avoids a few reallocations.

 Decompressing the empty byte string returns the empty byte string.

 Corrupt input raises @racket[exn:fail] with a descriptive message. Two
 conditions are detected:

 @itemlist[
  @item{a truncated stream---a literal run, offset byte, or length byte
   running past the end of @racket[bs] (the C decoder reports @tt{EINVAL}
   for these under @tt{CHECK_INPUT});}
  @item{a back reference reaching before the start of the output (the C
   decoder's @tt{ref < out_data} @tt{EINVAL} case).}
 ]
}

@section[#:tag "lzf-examples"]{Examples}

@interaction[#:eval lzf-eval
(define data (bytes-append (make-bytes 40 65) #" and some real text..."))
(define compressed (lzf-compress data))
(bytes-length compressed)
(bytes=? (lzf-decompress compressed) data)
]

Both directions treat the empty byte string as empty:

@interaction[#:eval lzf-eval
(lzf-compress "")
(lzf-decompress "")
]

Decoding corrupt data raises @racket[exn:fail]; it never crashes:

@interaction[#:eval lzf-eval
(eval:error (lzf-decompress #"\x20\x05"))
]

@section[#:tag "lzf-notes"]{Implementation notes}

@itemlist[
 @item{The hash-table configuration (table size, insertion policy) affects
  compression @emph{ratio} only, never the emitted format, so this codec is
  bit-compatible with every liblzf build.}
 @item{Unlike liblzf's default build---which leaves its hash table
  uninitialized on the stack---this implementation zero-initializes the
  table, which is what makes the output deterministic.}
 @item{The decoder validates back-reference reach and stream completeness
  but, like the C decoder, does not attempt checksums; LZF has no integrity
  metadata. Pair it with an external checksum if corruption matters.}
]

@section[#:tag "lzf-license"]{License}

MIT. See the @tt{LICENSE} file in the package distribution.
