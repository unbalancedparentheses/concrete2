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
| 20 | MAL-style Lisp interpreter | Identity | known staged interpreter workload with tests; reader/evaluator/env pressure | 15k-25k | Rust, Zig, C |

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
5. MAL-style Lisp interpreter

These are especially important because they stress:

- explicit authority
- visible trust boundaries
- high-integrity profile direction
- report usefulness
- reviewability under real code size
- interpreter/runtime pressure against a known external target rather than only internal examples

## Suggested Rollout Order

The full 20-program suite should not be attempted in arbitrary order.

The best early sequence is:

1. policy/rule engine
2. MAL-style Lisp interpreter
3. JSON parser + validator
4. grep-like text search tool
5. bytecode VM / interpreter
6. artifact/update verifier
7. small TCP/HTTP service
8. file tree scanner + policy checker
9. inverted index / search core
10. protocol/message validator

This is a reordering, not a replacement. The original early comparison-heavy set is still intentionally present:

1. JSON parser + validator
2. grep-like text search tool
3. bytecode VM / interpreter
4. policy/rule engine
5. artifact/update verifier
6. MAL-style Lisp interpreter

The only change is implementation order: the identity-heavy policy engine now comes first and MAL moves up to second, while the JSON / grep / VM / artifact-verifier workloads remain part of the same early Phase H tranche.

This gives:

- an immediate identity-heavy workload
- an immediate known interpreter/runtime workload
- parser-heavy pressure
- text-heavy pressure
- control-flow/runtime pressure
- identity-heavy pressure
- networking pressure
- one known interpreter target with an external staged test shape

## Interpreter Target

The recommended interpreter/runtime workload is **MAL-style Lisp**, not an ad hoc Scheme or Common Lisp subset.

For implementation order, MAL should be the **second Phase H program**, immediately after the first policy/rule-engine workload.

Why MAL is the right target:

- it is a known staged implementation target rather than a vague "tiny Lisp"
- it comes with a strong external comparison story and existing test material
- it stresses reader/parser, AST/value representation, environments, evaluation, errors, and REPL/runtime structure
- it is large enough to reveal real language/runtime ergonomics without exploding into full-language implementation sprawl

The intent is not to turn Phase H into "build a scripting language ecosystem." The intent is to include one recognizable interpreter workload that:

- is interesting outside the Concrete project
- has clear Rust/Zig/C comparison value
- reveals how Concrete handles dynamic-language runtime structure, allocation pressure, and sustained module growth

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
