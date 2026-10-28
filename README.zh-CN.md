# lzf — pure-Racket LZF compression

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/lzf/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/lzf/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`lzf` 是 **LZF** 压缩格式的纯 Racket 实现。LZF 是 Marc Alexander
Lehmann 的 [liblzf](https://github.com/nullgemm/liblzf) 所生产与消费的
字节级格式。它是一个面向该*格式*的编解码器，而不是对 C 库的绑定：没有
FFI，也没有系统依赖。

同一格式在现实中还出现在：

- **Redis RDB** 持久化文件中的压缩字符串编码（Redis 源码树中的
  `src/lzf_c.c` / `src/lzf_d.c`），
- Python 的 **`python-lzf`** 模块所使用的交换格式。

`lzf-compress` 产生的字节串可由 liblzf 解压，`lzf-decompress` 也能读取
由 liblzf 生成的字节串。两个方向的实现均以 Redis 仓库中的参考 C 源码
为准。

## 安装

```
raco pkg install lzf                 # Racket 包目录安装
# 或者在仓库检出目录中：
raco pkg install --auto --link /path/to/lzf
```

## 用法

```racket
#lang racket/base
(require lzf)

(define compressed (lzf-compress #"some data, some data, some data"))
(define original   (lzf-decompress compressed))
```

### API

- **`(lzf-compress bs)` → `bytes?`** — 使用单槽哈希表（liblzf 的低内存
  配置，`HLOG = 13`）贪心压缩 `bs`。输出是确定性的：相同输入总是得到
  相同字节。压缩空字节串得到空字节串。

- **`(lzf-decompress bs [#:hint hint])` → `bytes?`** — 解压 liblzf 格式
  的流。`#:hint`（默认值：`max(64, 4 × (bytes-length bs))`）是对输出
  大小的初始猜测；猜测过小时输出缓冲区会自动增长，因此任何非负的
  hint 都会产生相同结果。输入损坏时（流被截断，或回溯引用越过输出的
  起始位置）抛出 `exn:fail`。解压空字节串得到空字节串。

## 格式说明

线上格式（见 `lzf_c.c` 中的注释）：

```
000LLLLL <L+1>              ; literal run, L+1 = 1..33 octets
LLLooooo oooooooo           ; back reference, L+2 octets, offset o+1
111ooooo LLLLLLLL oooooooo  ; back reference, L+9 octets, offset o+1
```

哈希表的配置（表大小、插入策略）只影响压缩*率*，绝不影响格式本身，
因此本编解码器与所有 liblzf 构建版本都位级兼容。本包沿用 liblzf 的
默认构建策略（`VERY_FAST` 风格的单槽插入），将表初始化为空（输出
确定，不同于 liblzf 默认未初始化的栈上表），并且与 liblzf 一样，绝不
向位置 0 发出回溯引用。

## API 文档与测试

[完整 Scribble API 手册](lzf/scribblings/lzf.scrbl)说明公开契约、
确定性编码、输出缓冲增长、错误输入及字节格式。文档示例在构建时执行。
[独立可运行示例](examples/quickstart.rkt)验证压缩/解压往返、
`#:hint 0` 时的缓冲增长、重复输入输出确定性和空字节串，
无需安装任何 liblzf 系统库。

在已安装 Racket 的仓库根目录执行：

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p lzf
racket examples/quickstart.rkt
raco setup --check-pkg-deps -l lzf
```

CI 在 Linux、Windows 与 macOS 上执行上述步骤。`lzf` 是公开的
collection 名称；软件包本身是 `info.rkt` 声明的 multi-collection 结构。

## 局限

- 纯 Racket 的速度足以应对交互式负载（大约比 C liblzf 慢一个数量级）；
  它不是吞吐关键型服务的直接替代品。

## 许可证

[MIT](LICENSE)
