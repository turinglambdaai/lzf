# lzf — pure-Racket LZF compression

`lzf` is a pure-Racket implementation of the **LZF** compression format, the
byte-level format produced and consumed by Marc Alexander Lehmann's
[liblzf](https://github.com/nullgemm/liblzf). It is a codec for the *format*,
not a binding to the C library: there is no FFI and no system dependency.

The same format appears in the wild as:

- the compressed-string encoding inside **Redis RDB** persistence files
  (`src/lzf_c.c` / `src/lzf_d.c` in the Redis tree),
- the interchange format of Python's **`python-lzf`** module.

`lzf-compress` produces byte strings that liblzf can decompress, and
`lzf-decompress` reads byte strings produced by liblzf. Both directions were
implemented against the reference C sources in the Redis repository.

## Installation

```
raco pkg install --auto --link /path/to/lzf
```

## Usage

```racket
(require lzf)

(define compressed (lzf-compress #"some data, some data, some data"))
(define original   (lzf-decompress compressed))
```

### API

- **`(lzf-compress bs)` → `bytes?`** — greedily compresses `bs` with a
  single-slot hash table (liblzf's low-memory configuration, `HLOG = 13`).
  The output is deterministic: the same input always yields the same bytes.
  Compressing the empty byte string yields the empty byte string.

- **`(lzf-decompress bs [#:hint hint])` → `bytes?`** — decompresses a
  liblzf-format stream. `#:hint` (default: `max(64, 4 × (bytes-length bs))`)
  is an initial guess for the output size; the output buffer grows
  automatically whenever the guess is too small, so any non-negative hint
  produces the same result. Raises `exn:fail` on corrupt input (truncated
  stream, or a back-reference reaching before the start of the output).
  Decompressing the empty byte string yields the empty byte string.

## Format notes

The wire format (see the comment in `lzf_c.c`):

```
000LLLLL <L+1>              ; literal run, L+1 = 1..33 octets
LLLooooo oooooooo           ; back reference, L+2 octets, offset o+1
111ooooo LLLLLLLL oooooooo  ; back reference, L+9 octets, offset o+1
```

The hash table configuration (table size, insertion policy) affects
compression *ratio* only — never the format — so this codec is
bit-compatible with every liblzf build. This package mirrors liblzf's
default build policy (`VERY_FAST`-style single-slot insertion), initializes
the table to empty (deterministic output, unlike liblzf's default
uninitialized stack table), and, like liblzf, never emits a back reference
into position 0.

## Limitations

- Pure-Racket speed is adequate for interactive workloads (roughly an order
  of magnitude slower than C liblzf); it is not a drop-in for
  throughput-critical services.

## License

[MIT](LICENSE)
