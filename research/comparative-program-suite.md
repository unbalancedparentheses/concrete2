# Comparative Program Suite

Status: exploratory

This note defines the large-program comparison suite for Concrete after the language surface has been disciplined enough to make sustained implementation pressure meaningful.

The goal is not only to produce benchmark numbers. The goal is to compare Concrete against neighboring systems languages through the same real programs and the same inputs, and to ask:

- are the programs correct?
- are they fast enough?
- how much memory do they use?
- how large are the binaries?
- how long do they take to compile?
- how much code do they require?
- how much unsafe/trusted/manual-boundary code do they need?
- how easy are they to audit and explain?

The suite should therefore compare:

- Concrete
- Rust
- Zig
- C

where that comparison is reasonable.

## Comparison Dimensions

Every program in the suite should be evaluated across the same broad dimensions:

| Dimension | Questions |
|-----------|-----------|
| Correctness | Do all implementations pass the same tests and edge cases? |
| Runtime | Throughput, latency, steady-state speed |
| Memory | Peak memory, allocation behavior, retained memory |
| Build cost | Compile time, rebuild time, incremental behavior |
| Binary size | Output size under comparable build modes |
| Code size | Approximate LOC and module/package structure |
| Trust surface | How much `unsafe`, FFI, or manual boundary code is needed? |
| Auditability | How easy is it to identify authority, allocation, trust, and cleanup boundaries? |

The point is to understand where Concrete is stronger, weaker, or simply different, not to reduce the comparison to one speed number.

## Portfolio Shape

The suite should contain 20 programs split across four buckets:

1. standard comparison-friendly workloads
2. systems / infrastructure workloads
3. data-structure / algorithm workloads
4. Concrete-identity / mission-critical workloads

This mix gives both:

- externally credible comparison points
- workloads that actually test Concrete's intended niche

## Recommended 20-Program Suite

| # | Program | Bucket | Why It Matters | Est. LOC | Compare Against |
|---|---------|--------|----------------|----------|-----------------|
| 1 | JSON parser + validator | Standard | parsing, trees, errors, allocation | 10k-15k | Rust, Zig, C |
| 2 | Schema-driven config/manifest checker | Standard | validation, diagnostics, policy logic | 10k-15k | Rust, Zig, C |
| 3 | grep-like text search tool | Standard | strings, files, streaming, performance | 10k-20k | Rust, Zig, C |
| 4 | log processing/query pipeline | Standard | parsing, transforms, aggregation | 15k-25k | Rust, Zig, C |
| 5 | bytecode VM / interpreter | Standard | dispatch, control flow, runtime values | 15k-25k | Rust, Zig, C |
| 6 | graph/search kernel | Standard | collections, queues, algorithmic pressure | 10k-20k | Rust, Zig, C |
| 7 | priority-queue / scheduler kernel | Standard | heaps, ordering, event flow | 10k-15k | Rust, Zig, C |
| 8 | inverted index / search core | Data structure | `HashMap`/`Vec` pressure, indexing | 20k-30k | Rust, Zig, C |
| 9 | diff / matcher engine | Data structure | strings, algorithms, memory behavior | 15k-25k | Rust, Zig, C |
| 10 | small TCP/HTTP service | Standard | networking, parsing, module structure | 15k-25k | Rust, Zig, C |
| 11 | file tree scanner + policy checker | Systems | paths, traversal, explicit authority | 10k-20k | Rust, Zig, C |
| 12 | package/archive indexer | Systems | file formats, hashing, metadata | 15k-25k | Rust, Zig, C |
| 13 | job/pipeline runner | Systems | process/file/env boundaries, errors | 15k-25k | Rust, Zig, C |
| 14 | parser + symbol table + AST checker | Systems | language-tool workload, diagnostics pressure | 20k-30k | Rust, Zig, C |
| 15 | text/template transformation engine | Systems | strings, parsing, output correctness | 10k-20k | Rust, Zig, C |
| 16 | policy/rule engine | Identity | explicit authority, auditability, decision logic | 15k-25k | Rust, Zig, C |
| 17 | artifact/update verifier | Identity | hashes, signatures, policy, critical path | 15k-25k | Rust, Zig, C |
| 18 | command authorization gatekeeper | Identity | narrow authority, audit reports, control boundary | 10k-20k | Rust, Zig, C |
| 19 | protocol/message validator | Identity | bounded parsing, correctness, high-integrity fit | 10k-20k | Rust, Zig, C |
| 20 | audited FFI wrapper subsystem | Identity | explicit trust boundary, wrapper discipline | 10k-15k | Rust, Zig, C |

## How To Use Existing Work

Where possible, these programs should reuse:

- existing benchmark problem shapes
- public datasets and benchmark inputs
- well-understood reference implementations

This keeps the suite comparable and avoids inventing a benchmark world that only Concrete knows how to play in.

Good inputs to reuse:

- JSON/config corpora
- real log files
- package/manifest corpora
- graph datasets
- protocol/message traces
- real file trees or archive collections

## Existing-Comparison-Friendly Subset

These are the best first programs for direct Rust/Zig/C credibility:

1. JSON parser + validator
2. grep-like text search tool
3. log processing/query pipeline
4. bytecode VM / interpreter
5. graph/search kernel
6. priority-queue / scheduler kernel
7. small TCP/HTTP service
8. diff / matcher engine

These workloads already have obvious equivalents in neighboring languages.

## Concrete-Identity Subset

These are the strongest programs for showing why Concrete should exist at all:

1. policy/rule engine
2. artifact/update verifier
3. command authorization gatekeeper
4. protocol/message validator
5. audited FFI wrapper subsystem

These are especially important because they stress:

- explicit authority
- visible trust boundaries
- high-integrity profile direction
- report usefulness
- reviewability under real code size

## Suggested Rollout Order

The full 20-program suite should not be attempted in arbitrary order.

The best early sequence is:

1. JSON parser + validator
2. grep-like text search tool
3. bytecode VM / interpreter
4. policy/rule engine
5. artifact/update verifier
6. small TCP/HTTP service
7. file tree scanner + policy checker
8. inverted index / search core
9. protocol/message validator
10. audited FFI wrapper subsystem

This gives:

- parser-heavy pressure
- text-heavy pressure
- control-flow/runtime pressure
- identity-heavy pressure
- networking and FFI pressure

before filling out the rest of the portfolio.

## Success Conditions

This suite is successful if it reveals:

- language design weaknesses that only appear at 10k-30k LOC
- stdlib gaps that integration tests do not expose
- diagnostics/tooling failures that only appear under sustained use
- package/build workflow friction
- codegen and allocation cliffs
- places where Concrete is genuinely more auditable or easier to constrain than Rust/Zig/C

It is not successful if it becomes:

- only a speed leaderboard
- only toy programs
- only workloads that favor LLVM micro-optimizations
- only internal demos with no comparison value
