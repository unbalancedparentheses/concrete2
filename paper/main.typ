#set document(
  title: "Concrete: Explicit Systems Programming With Visible Authority and Ownership",
  author: "Concrete Project Draft",
)
#set page(margin: (x: 1in, y: 1in))
#set text(font: "Libertinus Serif", size: 11pt)

#align(center)[
  = Concrete: Explicit Systems Programming With Visible Authority and Ownership
  Concrete Project Draft
]

= Abstract

Concrete is an experimental systems language built around one primary goal: make semantically important program facts visible enough to audit directly. In Concrete, authority is visible in function signatures, ownership is visible in value movement and cleanup, and low-level implementation unsafety is isolated by explicit trusted boundaries rather than being diffused through ordinary code. The language targets hosted systems programming without a garbage collector, without a virtual machine, and without a large hidden runtime. This paper summarizes the language model, the current compiler architecture, the execution and standard-library direction, and the evidence gained from sustained real-program pressure testing. The main result is not that Concrete already has the breadth of a mature systems ecosystem. It does not. The result is that a small language with visible authority and visible ownership can already carry parsers, interpreters, storage tools, integrity tooling, and networked programs while preserving a simpler audit story than abstraction-heavy alternatives.

= Introduction

Most systems languages claim some combination of performance, control, and safety. Concrete is aimed at a narrower but important target: auditability. The design question is not only whether a program is fast or memory-safe, but whether the language keeps the important parts of program behavior mechanically understandable. If a function allocates, that should be visible. If a function can read files, open sockets, or cross a foreign boundary, that should be visible. If a library relies on pointer-level implementation techniques, the containment boundary should be explicit and inspectable.

This motivation pushes the language toward a different set of tradeoffs than mainstream languages usually optimize for. Concrete prefers explicitness over abstraction towers, reportable compiler facts over opaque optimization folklore, and a small language surface over broad feature accumulation. The project is therefore best understood not as a broad Rust competitor, but as an attempt to identify a sharper point in the design space: explicit systems programming with visible authority, visible ownership, and a small runtime boundary.

= Thesis

The central claim of Concrete is that low-level software becomes easier to trust when three kinds of information stay visible in the source and remain recoverable in compiler artifacts:

- authority: what external effects the code is permitted to use
- ownership: what values must be consumed, cleaned up, or borrowed explicitly
- trust boundaries: where pointer-level implementation techniques and foreign calls are concentrated

This claim can be stated as a compact design objective. Let $f$ be a function. Then the language should make the following sets inspectable:

$A(f)$, the capability set required by $f$

$T(f)$, the trusted or unsafe boundaries crossed by $f$

$M(f)$, the allocation and cleanup obligations induced by $f$

Concrete is designed so that these sets are not hidden implementation details. They are intended to be visible in signatures, declaration forms, and compiler reports.

= Core Model

== Capabilities

Concrete uses named compile-time capabilities for semantic effects. A function that allocates, touches files, uses the console, opens the network, or crosses explicit low-level boundaries must declare the relevant authority in its signature. This makes effect requirements part of the user-visible interface rather than a body-level surprise.

The intended calling discipline is monotone: if $f$ calls $g$, then $A(g) subset.eq A(f)$. In other words, callers must explicitly carry the authority required by their callees. This is a simple rule, but it creates a much stronger audit surface than ambient access to files, networking, or allocation.

== Trusted containment

Concrete separates semantic effects from low-level implementation techniques. Capabilities describe what the code is allowed to do semantically. The `trusted` boundary marks where pointer arithmetic, raw pointer dereference, raw pointer assignment, and pointer-involving casts are intentionally concentrated. Foreign calls remain explicit through `with(Unsafe)` rather than being silently absorbed.

This yields a three-way split:

- capabilities for caller-visible semantic effects
- `trusted` for pointer-level containment
- `with(Unsafe)` for explicit foreign-boundary authority

The split matters because it avoids conflating "this code can allocate" with "this code performs raw pointer tricks internally." Those are different audit questions, and the language keeps them separate.

== Ownership and cleanup

Concrete uses linear types by default for structs and enums. Linear values must be consumed exactly once. This gives the language resource-safety pressure without a garbage collector. Cleanup is intended to remain explicit rather than being driven by hidden collector work or implicit destructor insertion. The addition of scoped `defer` reduces boilerplate while preserving the visibility of destruction paths.

The intended ownership model is therefore:

- Copy values may be reused freely
- linear values must be consumed exactly once
- borrows are explicit and scoped
- cleanup is explicit, often via `defer`

= A Small Formal Sketch

Concrete is not yet presented here with a full formal semantics. The project already has a proof boundary and a proof-eligible subset, but the current paper uses a lighter mathematical sketch to clarify the design.

Let a program be represented by a call graph $G = (V, E)$, where each vertex is a function. Associate with each function $f in V$:

$A(f)$: the declared capability set

$U(f)$: a Boolean indicating whether $f$ crosses an explicit unsafe or foreign boundary

$R(f)$: a report bundle containing compiler-derived facts such as authority traces, trusted wrappers, proof eligibility, layout, and allocation summaries

The design intent can be expressed by the following properties:

1. Signature visibility:
   for semantically effectful code, $A(f)$ is visible in the source signature.

2. Containment visibility:
   pointer-level implementation techniques are concentrated so that $U(f)$ is sparse and inspectable.

3. Report recoverability:
   relevant semantic facts about $f$ should be derivable into $R(f)$ from the ordinary compiler pipeline rather than from a second semantic system.

4. Proof-eligibility filter:
   a pure function with empty authority set, no trusted origin, and no foreign boundary can be considered a candidate for the provable fragment.

This sketch is intentionally narrow. It does not try to formalize all of Concrete. It only makes explicit the structural claim the project is making: important program facts should remain visible enough to inspect, compare, and eventually prove over stable compiler artifacts.

= Compiler And Execution Architecture

Concrete's current compiler pipeline runs:

`Parse -> Resolve -> Check -> Elab -> CoreCanonicalize -> CoreCheck -> Mono -> Lower -> SSAVerify -> SSACleanup -> EmitSSA -> clang`

The proof boundary sits after `CoreCheck` and before monomorphization, materialized as a validated Core artifact. This is important because it gives the project a semantically meaningful stage at which reports, proof-oriented extraction, and later artifact workflows can be anchored.

The execution model is deliberately thin. Concrete currently targets hosted systems programming on a POSIX-like environment with libc available. It has no garbage collector, no virtual machine, no hidden runtime initialization, no panic-unwind machinery, and no ambient cleanup hook. Programs begin in `main`, call into the compiled user program, and exit through ordinary process termination. Heap allocation currently goes through libc `malloc` and `realloc`, with abort-on-OOM as the explicit default policy.

This means Concrete does have a runtime boundary, but not a large managed runtime. The runtime boundary is the set of external symbols and conventions required to link and execute a compiled program.

= Standard Library Direction

Concrete's standard library is part of the language's safety story, not just a bag of utilities. The intended shape is:

- explicit about allocation
- explicit about ownership and handles
- bytes-first for low-level work
- small and sharp rather than broad
- neutral about future concurrency structure until that design is mature

The library is already structured into three layers:

- Core: pure computation and analysis-friendly modules
- Alloc: modules that rely on allocation but not on broader host services
- Hosted: modules that rely on POSIX and libc facilities such as files, networking, time, and processes

This layering matters because it makes host assumptions auditable now and creates a clean path toward stricter execution profiles later.

= Evidence From Real Programs

The strongest evidence for Concrete does not come from toy examples. It comes from the Phase H workload corpus, which includes a policy engine, a large MAL interpreter, a JSON parser, a grep-like tool, a bytecode virtual machine, an integrity verifier, a TOML parser, a file-integrity monitor, a key-value store, a simple HTTP server, and a Lox interpreter.

That corpus established several important points.

First, the language can already carry serious programs. Parsers, interpreters, CLI tools, storage workflows, integrity tooling, and networked code are no longer hypothetical targets.

Second, the claimed audit differentiator is real in code that matters. The integrity verifier is the clearest example: capability signatures are not decorative. They act as a readable security decomposition. Hashing logic can be visibly separated from file access and from console reporting.

Third, optimization folklore is a poor substitute for measurement. Early performance conclusions were distorted by compilation without optimization. Under `-O2`, Concrete matched Python and system tools on text-heavy workloads and matched C on a dispatch-heavy VM benchmark once a missed-inlining cliff in vec builtins was removed.

Fourth, explicit cleanup can become less noisy without becoming hidden. Scoped `defer` eliminated a substantial amount of repeated cleanup code in the JSON parser while preserving a clear destruction story.

= Evaluation

The main evidence from the current system can be summarized qualitatively as follows.

== Language viability

Phase H answered the question of basic viability. Concrete is no longer at the stage of proving that it can express real programs at all. That threshold has been crossed.

== Performance shape

The available evidence suggests that Concrete's overhead is not dominated by its explicit authority or ownership model. The clearest large gap found in the VM benchmark was due to backend shaping, specifically non-inlined vec builtins in a hot loop. Once corrected, the gap to C disappeared on that benchmark. This matters because it changes the interpretation of "language cost." The evidence points first to code generation shape, not to an inherent tax from the explicit model.

== Audit surface

Concrete's most unusual contribution is not raw speed. It is that capability requirements, trusted boundaries, and proof eligibility can already be surfaced through compiler reports over the ordinary compilation pipeline. This creates a tractable inspection story and suggests a future in which semantic regression checks can be built over artifact-level facts rather than over style rules and convention alone.

= What Concrete Is Not

Concrete is not a garbage-collected language. It is not a virtual-machine language. It is not trying to recreate a giant iterator, async, or abstraction ecosystem. It is also not claiming to have already solved package architecture, proof automation, backend plurality, or concurrency maturity.

These omissions are design choices as much as they are missing work. The project is deliberately trying to avoid paying complexity costs before there is evidence that they buy real value.

= Current Limitations

The present system still has clear limitations.

- package, artifact, and workspace architecture remain the largest structural gap
- the standard library still needs deeper systems-module polish and stronger integration coverage
- some Phase H follow-through items remain open, including collection maturity and remaining string ergonomics
- the runtime story is intentionally thin today and not yet mature in the sense of concurrency plurality or stricter bounded-allocation profiles
- the proof story is real but still narrow relative to the full language

These are not small details. They define the difference between a strong experimental compiler and a complete language system.

= Discussion

The key strategic question after Phase H is no longer whether Concrete works at all. It is whether the language's explicit patterns stabilize into good idioms rather than remaining honest but exhausting ceremony. This is the right question. A language that is explicit but unbearable has failed just as surely as a language that is convenient but opaque.

Concrete's current results are promising because several explicit patterns have already moved from burden to discipline. Scoped cleanup is better than it was. Capability signatures are proving their audit value. The standard library has enough shape to support real workloads. The compiler already emits enough semantic structure to support report-first inspection. The remaining work is to deepen these strengths without dissolving them into hidden mechanisms.

= Conclusion

Concrete is an attempt to make systems programming more inspectable by default. Its central bet is that visible authority, visible ownership, and explicit trusted boundaries can produce a language that is simultaneously low-level and easier to audit. The current implementation is incomplete, but the evidence from real programs is already strong enough to justify the direction. Concrete has shown that a small language with no garbage collector, no large hidden runtime, and a report-oriented compiler can already carry serious workloads. The next challenge is not proving that the model works once. It is preserving that model while the project grows into a fuller language system.

= References

[1] Compiler Architecture. `docs/ARCHITECTURE.md`.

[2] Safety Model. `docs/SAFETY.md`.

[3] Execution Model. `docs/EXECUTION_MODEL.md`.

[4] Standard Library Direction. `docs/STDLIB.md`.

[5] Value and Reference Model. `docs/VALUE_MODEL.md`.

[6] Provable Subset. `docs/PROVABLE_SUBSET.md`.

[7] Phase H Summary. `research/workloads/phase-h-summary.md`.
