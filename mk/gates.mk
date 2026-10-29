# GENERATED from scripts/tests/gates.tsv by scripts/gen/gates.py; do not edit. Change a row's make, claim,
# build, shell or cmd cell and run: python3 scripts/gen/gates.py --write. The Makefile includes this
# file; `make help` lists these targets under the heading below.

##@ Gates (generated from scripts/tests/gates.tsv)

.PHONY: test-api-boundary
test-api-boundary: build ## API-boundary gate (consumers use the boundary)
	$(NIX_DEVELOP) bash ./scripts/tests/check_compiler_api_boundary.sh

.PHONY: test-arith-redteam
test-arith-redteam: build ## Arithmetic red-team gate: overflow/neg/div-mod/shift traps + interp==compiled value agreement (Phase 6 #10)
	$(NIX_DEVELOP) bash ./scripts/tests/check_arith_redteam.sh

.PHONY: test-array-bounds
test-array-bounds: build ## Array-bounds gate (KNOWN_HOLES H8): raw a[i] is runtime-checked — OOB read/write/negative/nested/&mut trap
	$(NIX_DEVELOP) bash ./scripts/tests/check_array_bounds.sh

.PHONY: test-assume-migration
test-assume-migration: build ## Assert/assume migration gate (no-laundering)
	$(NIX_DEVELOP) bash ./scripts/tests/check_assume_migration.sh

.PHONY: test-assumptions
test-assumptions: build ## Assumption-tracking checks
	$(NIX_DEVELOP) bash ./scripts/tests/check_assumptions.sh

.PHONY: test-atomic-flip-entrance
test-atomic-flip-entrance: build ## R-0004 package 2: is the CallableId->DefinitionIdentity flip safe to perform?
	$(NIX_DEVELOP) bash ./scripts/tests/check_atomic_flip_entrance.sh

.PHONY: test-attestation-manifest
test-attestation-manifest: build ## Attestation manifest: table -> attested subject, on the real corpus
	$(NIX_DEVELOP) bash ./scripts/tests/check_attestation_manifest.sh

.PHONY: test-axiom-inventory
test-axiom-inventory: build ## Axiom-inventory gate (#print axioms over every proof_by theorem; docs/verification/AXIOMS.md)
	$(NIX_DEVELOP) bash ./scripts/tests/check_axiom_inventory.sh

.PHONY: test-backend-contracts
test-backend-contracts: build ## Backend-contract gate (codegen guarantees, no drift)
	$(NIX_DEVELOP) bash ./scripts/tests/check_backend_contracts.sh

.PHONY: test-bounds-migration
test-bounds-migration: build ## Array-bounds migration gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_bounds_migration.sh

.PHONY: test-build-identity-freshness
test-build-identity-freshness: build ## R-0004 package 3: the embedded compiler build identity matches its sources
	$(NIX_DEVELOP) bash ./scripts/tests/check_build_identity_freshness.sh

.PHONY: test-build-profiles
test-build-profiles: build ## Build-profiles gate: --profile/[profile]/default/--report profile mechanism, no codegen (Phase 6 #10 Stage 1)
	$(NIX_DEVELOP) bash ./scripts/tests/check_build_profiles.sh

.PHONY: test-builtin-semantics
test-builtin-semantics: build ## Builtin behavior single-sourced by detection: interp == compiled byte-equal per builtin + interp-PENDING inventory pin
	$(NIX_DEVELOP) bash ./scripts/tests/check_builtin_semantics.sh

.PHONY: test-bundle-smoke
test-bundle-smoke: build ## Evidence-bundle smoke test
	$(NIX_DEVELOP) bash ./scripts/tests/test_bundle_smoke.sh

.PHONY: test-bv-certificates
test-bv-certificates: build ## Independent DRAT check of bv_decide bit-blasting (drat-trim; skip-if-absent)
	$(NIX_DEVELOP_PROVERS) bash ./scripts/tests/check_bv_certificates.sh

.PHONY: test-byte-view
test-byte-view: build ## ByteView gate: owned, reference-free, stored zero-copy view + guards (Phase 5 #5a)
	$(NIX_DEVELOP) bash ./scripts/tests/check_byte_view.sh

.PHONY: test-bytes-text-boundary
test-bytes-text-boundary: build ## P7 #4: Bytes=raw / String,Text=validated UTF-8; to_string checked (Option), _unchecked names its obligation, argv validated, no stray String{ptr} construction
	$(NIX_DEVELOP) bash ./scripts/tests/check_bytes_text_boundary.sh

.PHONY: test-call-site-migration
test-call-site-migration: build ## Call-site precondition migration gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_call_site_migration.sh

.PHONY: test-callable-values
test-callable-values: build ## Callable-values gate (three context modes; &mut *ctx reborrow aliases, no copy)
	$(NIX_DEVELOP) bash ./scripts/tests/check_callable_values.sh

.PHONY: test-cap-poly-design
test-cap-poly-design: build ## Callable-values/capability design gate (fn-ptr smuggling stays closed; stdlib HOF freeze)
	$(NIX_DEVELOP) bash ./scripts/tests/check_capability_polymorphism_design.sh

.PHONY: test-capability-judgment
test-capability-judgment: build ## Capability-judgment gate (Phase 6.5): direct-call capability satisfaction/missing is one decision (Capabilities.decideCall) shared by Check, CoreCheck, and reports
	$(NIX_DEVELOP) bash ./scripts/tests/check_capability_judgment.sh

.PHONY: test-cast-matrix
test-cast-matrix: build ## Cast-matrix differential gate: every (source width x edge value) casts to every width identically in interp and compiled
	$(NIX_DEVELOP) bash ./scripts/tests/check_cast_matrix.sh

.PHONY: test-catches
test-catches: build ## Negative "the compiler catches this" examples
	$(NIX_DEVELOP) bash ./scripts/tests/check_catches.sh

.PHONY: test-checked-arith
test-checked-arith: build ## Checked-arith gate: ordinary + traps on overflow; wrapping_* escapes (Phase 6 #10 Stage 2.3)
	$(NIX_DEVELOP) bash ./scripts/tests/check_checked_arith.sh

.PHONY: test-checker-identity
test-checker-identity: build ## R-0208 slice 1a: receipts bind the checker that actually ran (loaded images), not lean-toolchain text
	$(NIX_DEVELOP) bash ./scripts/tests/check_checker_identity.sh

.PHONY: test-checker-policy
test-checker-policy: build ## R-0208 decisions 3-4: compiled checker advisory register, decided beside currency
	$(NIX_DEVELOP) bash ./scripts/tests/check_checker_policy.sh

.PHONY: test-ci-gates
test-ci-gates: build ## Run every gate the CI workflow runs, locally (the via=step rows of scripts/tests/gates.tsv; pre-push ritual, ROADMAP #34a)
	$(NIX_DEVELOP) bash ./scripts/tests/run_ci_gates_local.sh

.PHONY: test-classification-freshness
test-classification-freshness: build ## Classification table matches a fresh derivation (R-0004 slice 6) — MANDATORY, ~1s
	$(NIX_DEVELOP) bash ./scripts/tests/check_classification_freshness.sh

.PHONY: test-clean-checkout
test-clean-checkout: build ## R-0004 package 3: clean-checkout reproducibility and compiler provenance
	$(NIX_DEVELOP) bash ./scripts/tests/check_clean_checkout.sh

.PHONY: test-cli-coherence
test-cli-coherence: build ## Phase 6E gate: context-free help (never throws), alias==legacy byte identity, legacy flags intact, structured errors, help taxonomy complete
	$(NIX_DEVELOP) bash ./scripts/tests/check_cli_coherence.sh

.PHONY: test-cli-contract
test-cli-contract: build ## CLI-contract gate (golden command behavior matrix)
	$(NIX_DEVELOP) bash ./scripts/tests/check_cli_contract.sh

.PHONY: test-cli-helpers
test-cli-helpers: build ## std.cli v1: cli_tool matrix (flags/arity/13t exit codes) + bug-034 regression + proof-of-pull
	$(NIX_DEVELOP) bash ./scripts/tests/check_cli_helpers.sh

.PHONY: test-cli-plumbing
test-cli-plumbing: build ## CLI-plumbing gate (shared prologue + exit codes)
	$(NIX_DEVELOP) bash ./scripts/tests/check_cli_plumbing.sh

.PHONY: test-codegen-differential
test-codegen-differential: build ## Interp-vs-compiled differential gate (oracle agreement)
	$(NIX_DEVELOP) bash ./scripts/tests/check_codegen_differential.sh

.PHONY: test-codegen-execution
test-codegen-execution: build ## Codegen execution-oracle gate (compile-run-assert value, 30 cases)
	$(NIX_DEVELOP) bash ./scripts/tests/check_codegen_execution.sh

.PHONY: test-collections
test-collections: ## Collections gate: H1-clean surface (no returned refs) + value/op/scoped APIs (Phase 5 #6)
	$(NIX_DEVELOP) bash ./scripts/tests/check_collections.sh

.PHONY: test-collections-copy-only
test-collections-copy-only: build ## H18 gate: Vec<non-Copy>.drop leaks its elements (disclosed); the fix must land as the visible drop_with/clear_with/remove_with family
	$(NIX_DEVELOP) bash ./scripts/tests/check_collections_copy_only.sh

.PHONY: test-compile-scaling
test-compile-scaling: build ## R-0550 (exit 2o): generated 10^4-10^5-element programs compile within recorded per-stage budgets, each stage growing near-linearly between sizes (scripts/tests/lib/compile_scaling_budgets.tsv)
	$(NIX_DEVELOP) bash ./scripts/tests/check_compile_scaling.sh

.PHONY: test-compiler-complexity
test-compiler-complexity: build ## Phase 6C #2: anti-superlinear guard — fails if a compiler pass grows super-linearly on a scaling corpus (caught the SSAVerify dominator cubic; bug-027 family)
	$(NIX_DEVELOP) bash ./scripts/tests/check_compiler_complexity.sh

.PHONY: test-compiler-ledger
test-compiler-ledger: build ## CompilerLedger gate (non-proof fact store)
	$(NIX_DEVELOP) bash ./scripts/tests/check_compiler_ledger.sh

.PHONY: test-concrete-fmt
test-concrete-fmt: build ## `concrete fmt` gate: subcommand contract + semantics-preserving formatting (Phase 6 #1)
	$(NIX_DEVELOP) bash ./scripts/tests/check_concrete_fmt.sh

.PHONY: test-concrete-test
test-concrete-test: build ## `concrete test` gate: project-mode test runner (Phase 5 #3)
	$(NIX_DEVELOP) bash ./scripts/tests/check_concrete_test.sh

.PHONY: test-construction-rights
test-construction-rights: build ## 0b: representation private-by-default across modules (newtype construct + struct field read/write/literal rejected; pub escape + accessors work)
	$(NIX_DEVELOP) bash ./scripts/tests/check_construction_rights.sh

.PHONY: test-contract-clause-migration
test-contract-clause-migration: build ## Contract-clause migration gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_contract_clause_migration.sh

.PHONY: test-contract-negatives
test-contract-negatives: build ## Contract-negatives gate (source-contract hardening)
	$(NIX_DEVELOP) bash ./scripts/tests/check_contract_negatives.sh

.PHONY: test-contract-stability
test-contract-stability: build ## Contract-stability gate (contract API drift)
	$(NIX_DEVELOP) bash ./scripts/tests/check_contract_stability.sh

.PHONY: test-contracts-ledger-parity
test-contracts-ledger-parity: build ## --report contracts ↔ ledger parity (#15/#18e)
	$(NIX_DEVELOP) bash ./scripts/tests/check_contracts_ledger_parity.sh

.PHONY: test-copy-judgment
test-copy-judgment: build ## Copy-judgment gate (Phase 6.5): the one Copy judgment (Layout.isCopyTyGeneric) is shared by Check and the Core stages so they cannot drift on Copy-ness
	$(NIX_DEVELOP) bash ./scripts/tests/check_copy_judgment.sh

.PHONY: test-corecheck-boundary
test-corecheck-boundary: build ## CoreCheck boundary gate (Phase 6.5 #4): every frontend/mono/type-policy residue class is rejected before Lower (see docs/compiler/COMPILER_BOUNDARY.md)
	$(NIX_DEVELOP) bash ./scripts/tests/check_corecheck_boundary.sh

.PHONY: test-counterexample-reduction
test-counterexample-reduction: build ## Phase 6C #4: pipeline failures reduce to a minimized `.con` fixture + replay command (error/trap/oracle/report predicate paths); reduced fixture still reproduces
	$(NIX_DEVELOP) bash ./scripts/tests/check_counterexample_reduction.sh

.PHONY: test-coverage-baseline
test-coverage-baseline: build ## R-0004 package 3: eligibility-denominated coverage, every disposition named
	$(NIX_DEVELOP) bash ./scripts/tests/check_coverage_baseline.sh

.PHONY: test-defer
test-defer: build ## defer gate: LIFO + runs-on-every-exit-path; block-form rejected (Phase 6 #7)
	$(NIX_DEVELOP) bash ./scripts/tests/check_defer.sh

.PHONY: test-diagnostics-quality
test-diagnostics-quality: build ## Diagnostics-quality gate: span floor + reason/next-action exemplar (Phase 5 #4)
	$(NIX_DEVELOP) bash ./scripts/tests/check_diagnostics_quality.sh

.PHONY: test-differential-positions
test-differential-positions: build ## Differential-position gate: flexible overflow across syntactic positions + signed shift width wrapping agree interp==compiled (the 2026-07 sweep's permanent guard)
	$(NIX_DEVELOP) bash ./scripts/tests/check_differential_positions.sh

.PHONY: test-discharge-adapters
test-discharge-adapters: build ## Backend discharge-adapter gate (evidence firewall)
	$(NIX_DEVELOP) bash ./scripts/tests/check_discharge_adapters.sh

.PHONY: test-div-migration
test-div-migration: build ## Div/mod + sound-lowering migration gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_div_migration.sh

.PHONY: test-divergence-detection
test-divergence-detection: build ## Divergence gate: each arm of stmtDiverges lifts E0213 for an if-without-else, the same shapes without divergence stay refused, and accepted rows compile+run equal to --interp (bug 078)
	$(NIX_DEVELOP) bash ./scripts/tests/check_divergence_detection.sh

.PHONY: test-doc-links
test-doc-links: ## Markdown links and anchors resolve (no build needed)
	$(NIX_DEVELOP) bash ./scripts/tests/check_doc_links.sh

.PHONY: test-doc-snippets
test-doc-snippets: build ## 13r: every ```con/```concrete doc block compiles (--emit-core), rejects as declared (reject:E0xxx), or is marked pseudocode
	$(NIX_DEVELOP) bash ./scripts/tests/check_doc_snippets.sh

.PHONY: test-enum-union-layout
test-enum-union-layout: build ## Enum union layout gate: canonical Option/Result covers worst alignment-aware footprint; align-8 allocas (audit 2026-07-16)
	$(NIX_DEVELOP) bash ./scripts/tests/check_enum_union_layout.sh

.PHONY: test-envcfg
test-envcfg: build ## P7 workload 5: envcfg env-override matrix (hermetic via env -u) + 13t exit codes + bug-039 leg
	$(NIX_DEVELOP) bash ./scripts/tests/check_envcfg.sh

.PHONY: test-error-conventions
test-error-conventions: build ## 13t gate: recoverable (ignored Result -> E0286), fatal (trap_sites in telemetry), policy-gated (caps names File) — one public API per bucket, report-visible
	$(NIX_DEVELOP) bash ./scripts/tests/check_error_conventions.sh

.PHONY: test-evidence-corpus
test-evidence-corpus: build ## Evidence-class corpus integrity gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_evidence_corpus.sh

.PHONY: test-evidence-reproducibility
test-evidence-reproducibility: build ## R-0004 package 3: identities/roots/correspondence are properties of the program, not its path
	$(NIX_DEVELOP) bash ./scripts/tests/check_evidence_reproducibility.sh

.PHONY: test-exit-codes
test-exit-codes: build ## MAIN_EXIT_MODEL (stage 2 complete): main return = process exit code (8-bit masked, clean stdout); the legacy echo env is pinned IGNORED
	$(NIX_DEVELOP) bash ./scripts/tests/check_exit_codes.sh

.PHONY: test-fast-surface-gates
test-fast-surface-gates: build ## R-0022: the ONE fast fail-closed surface-gate checklist (E-codes, append ratchet, API/IR inventory, manifest, capability facts, construction/visibility, drift). Identical local + CI. Prints the exact failing constituent.
	$(NIX_DEVELOP) bash ./scripts/tests/run_fast_surface_gates.sh

.PHONY: test-fast-surface-gates-mutate
test-fast-surface-gates-mutate: build ## R-0022 gate-the-gate: prove the aggregate goes RED when a representative row is removed from each row-bearing inventory family
	$(NIX_DEVELOP) bash ./scripts/tests/run_fast_surface_gates.sh --mutate

.PHONY: test-float-cast
test-float-cast: build ## Checked float->int cast gate: NaN/inf/out-of-range abort, in-range truncates (Phase 6 #10, closed H2)
	$(NIX_DEVELOP) bash ./scripts/tests/check_float_cast.sh

.PHONY: test-float-literals
test-float-literals: build ## Float-literal rounding gate: lexer == CPython float() bits over 8022 cases (audit 2026-07-16)
	$(NIX_DEVELOP) bash ./scripts/tests/check_float_literals.sh

.PHONY: test-fuzz
test-fuzz: build ## Parser fuzzing
	$(NIX_DEVELOP) bash ./scripts/tests/test_parser_fuzz.sh

.PHONY: test-gate-mutation-coverage
test-gate-mutation-coverage: build ## Phase 6C #5 (HEAVY/nightly — rebuilds per mutation): disable one rule per family, prove its specific gate goes red; FAMILY=<n> for one
	$(NIX_DEVELOP) bash ./scripts/tests/check_gate_mutation_coverage.sh

.PHONY: test-gate-vacuity
test-gate-vacuity: ## Vacuity ratchet: gates that cannot fail (universal-over-empty, absence-over-no-output)
	$(NIX_DEVELOP) bash ./scripts/tests/check_gate_vacuity.sh

.PHONY: test-golden
test-golden: build ## Golden baselines for --emit-core, --emit-ssa, --fmt
	$(NIX_DEVELOP) bash ./scripts/tests/test_golden.sh

.PHONY: test-hexdump
test-hexdump: build ## P7 workload 3: hexdump byte-identical to xxd (default/-s/-n/edges) + 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_hexdump_differential.sh

.PHONY: test-httpget
test-httpget: build ## P7 workload 7: httpget over loopback TCP byte-identical to served file (text+binary) + curl cross-check + 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_httpget_differential.sh

.PHONY: test-ignored-result
test-ignored-result: build ## Ignored-result gate: discarded Result/Option rejected (E0286) unless `let _ =` acknowledged (Phase 6 #13)
	$(NIX_DEVELOP) bash ./scripts/tests/check_ignored_result.sh

.PHONY: test-impl-manifest
test-impl-manifest: build ## Implementation manifest accounting on the real corpus (R-0004 slice 6) — shadow
	$(NIX_DEVELOP) bash ./scripts/tests/check_impl_manifest.sh

.PHONY: test-incremental-shadow
test-incremental-shadow: build ## Phase 6C #7: cache-free incremental shadow — per-query reuse/invalidate prediction over an edit corpus; a false reuse (missing dependency edge) is a hard failure
	$(NIX_DEVELOP) bash ./scripts/tests/check_incremental_shadow.sh

.PHONY: test-io-writer
test-io-writer: build ## P7 14a: Writer discipline — fixed sink no-Alloc, File/Console/Unsafe at acquisition, cap-free methods, one handle shape, no dyn/enum sinks
	$(NIX_DEVELOP) bash ./scripts/tests/check_io_writer.sh

.PHONY: test-iteration-protocol
test-iteration-protocol: build ## Iteration-protocol gate: for/cursor/for_each/fold/map forms + no Iterator-trait/dyn/closure (Phase 6 #17)
	$(NIX_DEVELOP) bash ./scripts/tests/check_iteration_protocol.sh

.PHONY: test-kernel-recheck
test-kernel-recheck: build ## R-0208 slice 1b: receipts mint only for theorems the kernel re-checked in the replay run
	$(NIX_DEVELOP) bash ./scripts/tests/check_kernel_recheck.sh

.PHONY: test-lean14576
test-lean14576: build ## R-0208 fire drill: the retained upstream reproducer, isolated, against the pinned checker
	$(NIX_DEVELOP) bash ./scripts/tests/check_lean14576_reproducer.sh

.PHONY: test-lex-escapes
test-lex-escapes: build ## Escape gate: unknown string/char escapes and unterminated literals are E0001, never silently mangled
	$(NIX_DEVELOP) bash ./scripts/tests/check_lex_escapes.sh

.PHONY: test-linear-conservation
test-linear-conservation: build ## Linear-conservation gate: every value-flow site (let/array-lit/struct-lit/destructure/arg/return/match) MOVES a linear value exactly once — no duplication
	$(NIX_DEVELOP) bash ./scripts/tests/check_linear_conservation.sh

.PHONY: test-linear-discard
test-linear-discard: build ## Linear-discard gate (KNOWN_HOLES H6): silent discard of a non-Copy value is rejected; `let _ =`/free/consumed compile
	$(NIX_DEVELOP) bash ./scripts/tests/check_linear_discard.sh

.PHONY: test-linear-nested-scope
test-linear-nested-scope: build ## Nested-scope linearity gate (KNOWN_HOLES H9): a linear value in an if/else branch or match arm must be consumed; move-through-let; while-true/abort exempt
	$(NIX_DEVELOP) bash ./scripts/tests/check_linear_nested_scope.sh

.PHONY: test-loop-control
test-loop-control: build ## Loop-control gate: break/continue/labeled/while-expr value + linear cleanup (Phase 6 #4)
	$(NIX_DEVELOP) bash ./scripts/tests/check_loop_control.sh

.PHONY: test-loop-migration
test-loop-migration: build ## Loop-obligation migration gate (O1-O5 scoped)
	$(NIX_DEVELOP) bash ./scripts/tests/check_loop_migration.sh

.PHONY: test-lzpack
test-lzpack: build ## P7 workload 9: lzpack LZSS/RLE streams byte-identical to an independent Python encoder, cross-decoding, corrupt-stream exit codes, 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_lzpack_differential.sh

.PHONY: test-memory-model
test-memory-model: build ## Memory-model gate: no uninitialized reads by construction (Phase 6 #33)
	$(NIX_DEVELOP) bash ./scripts/tests/check_memory_model.sh

.PHONY: test-mixed-width-binops
test-mixed-width-binops: build ## Mixed-width gate: numeric binop operands must agree exactly (E0228); literals stay flexible; interp normalizes as-casts
	$(NIX_DEVELOP) bash ./scripts/tests/check_mixed_width_binops.sh

.PHONY: test-module-visibility
test-module-visibility: build ## Module/import/visibility gate (Phase 5 #1)
	$(NIX_DEVELOP) bash ./scripts/tests/check_module_visibility.sh

.PHONY: test-mono-collision
test-mono-collision: build ## Mono name-collision known-hole gate (nested-generic specializations merge)
	$(NIX_DEVELOP) bash ./scripts/tests/check_mono_name_collision.sh

.PHONY: test-multi-kernel
test-multi-kernel: build ## Multi-kernel evidence gate (Rocq/Isabelle; skip-if-absent)
	$(NIX_DEVELOP_PROVERS) bash ./scripts/tests/check_multi_kernel.sh

.PHONY: test-mutation
test-mutation: build ## Mutation testing for the compiler: each targeted source mutation must be killed by a gate (HEAVY: rebuilds per mutation; refuses outside the gate shell)
	$(NIX_DEVELOP) bash ./scripts/tests/test_mutation.sh

.PHONY: test-nested-field-write
test-nested-field-write: build ## Nested place-write regression gate (o.inner.v / a[i].x / m[i][j])
	$(NIX_DEVELOP) bash ./scripts/tests/check_nested_field_write.sh

.PHONY: test-nested-patterns
test-nested-patterns: build ## Nested-patterns decision gate: one level/arm; deeper stays rejected + workarounds (Phase 6 #5)
	$(NIX_DEVELOP) bash ./scripts/tests/check_nested_patterns.sh

.PHONY: test-no-duplicate-walkers
test-no-duplicate-walkers: ## No-duplicate-obligation-walkers guard
	$(NIX_DEVELOP) bash ./scripts/tests/check_no_duplicate_obligation_walkers.sh

.PHONY: test-no-macros
test-no-macros: build ## Macro-stance gate: no v1 macros; macro/derive syntax stays rejected (Phase 6 #11)
	$(NIX_DEVELOP) bash ./scripts/tests/check_no_macros.sh

.PHONY: test-no-quadratic-append
test-no-quadratic-append: ## Ratchet: no new `xs ++ [x]` (O(n²) per-element append) in the hot pipeline files — the shape behind the 6C#2 O(n²) family
	$(NIX_DEVELOP) bash ./scripts/tests/check_no_quadratic_append.sh

.PHONY: test-no-tuples
test-no-tuples: build ## No-tuples decision gate: tuple syntax stays rejected, use named structs (Phase 6 #5)
	$(NIX_DEVELOP) bash ./scripts/tests/check_no_tuples.sh

.PHONY: test-numeric-literals
test-numeric-literals: build ## Numeric-literals gate: out-of-range literals rejected (E0227), in-range compile (Phase 6 #6)
	$(NIX_DEVELOP) bash ./scripts/tests/check_numeric_literals.sh

.PHONY: test-obligation-core
test-obligation-core: build ## ObligationCore ledger gate (schema + vocabulary)
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_core.sh

.PHONY: test-obligation-lowering
test-obligation-lowering: build ## Obligation-expression lowering gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_lowering.sh

.PHONY: test-obligation-policy-views
test-obligation-policy-views: build ## Policy-as-ledger-view gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_policy_views.sh

.PHONY: test-obligation-prove-views
test-obligation-prove-views: build ## prove-as-ledger-view gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_prove_views.sh

.PHONY: test-obligation-redteam
test-obligation-redteam: build ## ObligationCore red-team gate (hardening)
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_redteam.sh

.PHONY: test-obligation-report-views
test-obligation-report-views: build ## Reports-as-views gate (ledger consistency)
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_report_views.sh

.PHONY: test-one-producer
test-one-producer: ## One producer per fact: formula copies and unregistered consumers (grep-only, ~1s)
	$(NIX_DEVELOP) bash ./scripts/tests/check_one_producer.sh

.PHONY: test-operational-vc-autodischarge
test-operational-vc-autodischarge: build ## Operational-VC-auto-discharge forcing-probe gate (Phase 9 #16a)
	$(NIX_DEVELOP) bash ./scripts/tests/check_operational_vc_auto_discharge.sh

.PHONY: test-oracle
test-oracle: build ## Differential oracle tests
	$(NIX_DEVELOP) bash ./scripts/tests/test_oracle.sh

.PHONY: test-overflow-migration
test-overflow-migration: build ## Overflow migration gate (three-route parity)
	$(NIX_DEVELOP) bash ./scripts/tests/check_overflow_migration.sh

.PHONY: test-ownership-judgment
test-ownership-judgment: build ## Ownership matrix (Phase 6.5): Check accept/reject == Lower move/drop == interp consumption, across the linearity matrix
	$(NIX_DEVELOP) bash ./scripts/tests/check_ownership_judgment.sh

.PHONY: test-partial-facts
test-partial-facts: build ## Partial-facts gate (error-tolerant diagnostics)
	$(NIX_DEVELOP) bash ./scripts/tests/check_partial_facts.sh

.PHONY: test-pass-hashes
test-pass-hashes: build ## Phase 6C #6: per-stage pass-output hash manifest + replay commands; determinism + comment-invariance (core/fingerprints) vs position-bearing (ssa/obligations) + structural sensitivity
	$(NIX_DEVELOP) bash ./scripts/tests/check_pass_hashes.sh

.PHONY: test-pattern-ergonomics
test-pattern-ergonomics: build ## Pattern-ergonomics gate: range patterns (+ future guards/OR/...) (Phase 6 #5)
	$(NIX_DEVELOP) bash ./scripts/tests/check_pattern_ergonomics.sh

.PHONY: test-phase1-contracts
test-phase1-contracts: build ## Phase 1 contracts validation artifact (umbrella)
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase1_contracts.sh

.PHONY: test-phase2-vc
test-phase2-vc: build ## Phase 2 VC/discharge validation artifact (umbrella)
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase2_vc.sh

.PHONY: test-phase3-obligation-core
test-phase3-obligation-core: build ## Phase 3 capstone umbrella (single truth source)
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase3_obligation_core.sh

.PHONY: test-phase6-redteam
test-phase6-redteam: build ## Red-team gate: parser recovery, match consumption/lowering, fingerprint stability, stale fixtures (Phase 6 #35a)
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase6_redteam.sh

.PHONY: test-phase6c
test-phase6c: build ## Phase 6C #8 capstone: run the full observability suite (#1 telemetry, #2 complexity, #3 trace, #4 reduction, #5 mutation sample, #6 pass-hashes, #7 shadow)
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase6c_observability.sh

.PHONY: test-phase6d
test-phase6d: build ## Phase 6D #6 capstone: LL(1) + removed-form negatives (fn-bang, value while, postfix ->) + migrated-form behavior + 6B ownership/agreement gates + capability-visible unsafe
	$(NIX_DEVELOP) bash ./scripts/tests/check_phase6d_surface_simplification.sh

.PHONY: test-pipeline-refactor-contract
test-pipeline-refactor-contract: build ## Phase 6B capstone (item 32): a corpus proving the composed pipeline is behavior-preserving for accepted programs (interp==compiled) and fail-closed per axis for malformed ones
	$(NIX_DEVELOP) bash ./scripts/tests/check_pipeline_refactor_contract.sh

.PHONY: test-pipeline-telemetry
test-pipeline-telemetry: build ## Phase 6C #1: `concrete <file> --emit-trace-json` emits a stable-schema per-stage structural-count trace (schema stability + no private paths gated; timing/RSS deferred to Phase 17)
	$(NIX_DEVELOP) bash ./scripts/tests/check_pipeline_telemetry.sh

.PHONY: test-policy
test-policy: build ## Policy enforcement checks
	$(NIX_DEVELOP) bash ./scripts/tests/check_policy.sh

.PHONY: test-project-model
test-project-model: build ## Project-model gate: Concrete.toml structure + anti-ambient-config (Phase 5 #2)
	$(NIX_DEVELOP) bash ./scripts/tests/check_project_model.sh

.PHONY: test-proof-link-migration
test-proof-link-migration: build ## Proof-link freshness migration gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_proof_link_migration.sh

.PHONY: test-proof-namespace
test-proof-namespace: ## Proof-namespace guard (Examples.* only)
	$(NIX_DEVELOP) bash ./scripts/tests/check_proof_namespace.sh

.PHONY: test-proof-patterns
test-proof-patterns: build ## Proof-patterns corpus gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_proof_patterns.sh

.PHONY: test-proofkit-arith
test-proofkit-arith: build ## ProofKit arithmetic-bridge gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_proofkit_arith.sh

.PHONY: test-prove-cli
test-prove-cli: build ## `concrete prove` CLI gate
	$(NIX_DEVELOP) bash ./scripts/tests/test_prove_cli.sh

.PHONY: test-proven-violation
test-proven-violation: build ## Proven-violation known-hole gate (constant OOB / div-zero compile today)
	$(NIX_DEVELOP) bash ./scripts/tests/check_proven_violation_enforcement.sh

.PHONY: test-purecore-proofs
test-purecore-proofs: build ## Proof arc slice 1: unwrap_or kernel-verified + fingerprint-fresh + mutation-sensitive; trusted fns stay link-excluded
	$(NIX_DEVELOP) bash ./scripts/tests/check_purecore_proofs.sh

.PHONY: test-raw-ptr-to-local
test-raw-ptr-to-local: build ## Raw-ptr-to-local known-hole gate (&mut x does not alias local)
	$(NIX_DEVELOP) bash ./scripts/tests/check_raw_ptr_to_local.sh

.PHONY: test-receipt-consumption
test-receipt-consumption: build ## R-0004 package 3: a stored receipt is untrusted input, re-checked against fresh facts
	$(NIX_DEVELOP) bash ./scripts/tests/check_receipt_consumption.sh

.PHONY: test-receipt-issuance
test-receipt-issuance: build ## R-0004 package 3: production receipt issuance follows the composed authority verdict
	$(NIX_DEVELOP) bash ./scripts/tests/check_receipt_issuance.sh

.PHONY: test-reducer-smoke
test-reducer-smoke: build ## Test-case reducer smoke test
	$(NIX_DEVELOP) bash ./scripts/tests/test_reducer_smoke.sh

.PHONY: test-registry-retirement
test-registry-retirement: ## Registry-retirement gate (no JSON example registries)
	$(NIX_DEVELOP) bash ./scripts/tests/check_no_example_registries.sh

.PHONY: test-release-bundle
test-release-bundle: build ## Release bundle capture test
	$(NIX_DEVELOP) bash ./scripts/tests/test_release_bundle.sh

.PHONY: test-replay-producer
test-replay-producer: build ## R-0004 package 3: kernel replay is one typed producer whose failures are values
	$(NIX_DEVELOP) bash ./scripts/tests/check_replay_producer.sh

.PHONY: test-report-arithmetic
test-report-arithmetic: build ## --report arithmetic gate: per-site classification (runtime-checked/proved/wrapping/saturating) (Phase 6 #10 §3.2)
	$(NIX_DEVELOP) bash ./scripts/tests/check_report_arithmetic.sh

.PHONY: test-returned-ref-provenance
test-returned-ref-provenance: build ## Known hole: returned-ref provenance + aggregate-ref public API freeze
	$(NIX_DEVELOP) bash ./scripts/tests/check_returned_ref_provenance.sh

.PHONY: test-rich-diagnostics
test-rich-diagnostics: build ## Rich-diagnostics gate (human/JSON from one record)
	$(NIX_DEVELOP) bash ./scripts/tests/check_rich_diagnostics.sh

.PHONY: test-saturating-arith
test-saturating-arith: build ## Saturating-arith gate: saturating_add/sub clamp at bounds (interp==compiled), integer-only (Phase 6 #10 Stage 2.2)
	$(NIX_DEVELOP) bash ./scripts/tests/check_saturating_arith.sh

.PHONY: test-scoped-collector
test-scoped-collector: build ## Unified scoped-collector gate (adversarial)
	$(NIX_DEVELOP) bash ./scripts/tests/check_scoped_collector.sh

.PHONY: test-showcase
test-showcase: build ## Showcase gate (graduated flagships stay graduated)
	$(NIX_DEVELOP) bash ./scripts/tests/check_showcase.sh

.PHONY: test-single-truth-source
test-single-truth-source: ## Single-truth-source guard (ObligationCore)
	$(NIX_DEVELOP) bash ./scripts/tests/check_obligation_single_truth_source.sh

.PHONY: test-slice8-adversarial
test-slice8-adversarial: build ## R-0004 Slice 8: adversarial attacks on the receipt store, through the production consumer
	$(NIX_DEVELOP) bash ./scripts/tests/check_slice8_adversarial.sh

.PHONY: test-smt-examples
test-smt-examples: build ## External-SMT teaching group gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_examples.sh

.PHONY: test-smt-negatives
test-smt-negatives: build ## SMT negatives gate (honesty boundaries)
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_negatives.sh

.PHONY: test-smt-path
test-smt-path: build ## External-SMT path gate (trust boundary)
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_path.sh

.PHONY: test-smt-policy
test-smt-policy: build ## SMT release-policy gate (evidence governance)
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_policy.sh

.PHONY: test-smt-redteam
test-smt-redteam: build ## Red-team VC/SMT gate (adversarial)
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_redteam.sh

.PHONY: test-smt-replay
test-smt-replay: build ## Lean-replay gate (SMT -> kernel upgrade artifact)
	$(NIX_DEVELOP) bash ./scripts/tests/check_smt_replay.sh

.PHONY: test-snapshots
test-snapshots: build ## Diagnostic snapshot tests
	$(NIX_DEVELOP) bash ./scripts/tests/check_snapshots.sh

.PHONY: test-source-maps
test-source-maps: build ## Source-maps gate (spans survive AST -> Core)
	$(NIX_DEVELOP) bash ./scripts/tests/check_source_maps.sh

.PHONY: test-ssa
test-ssa: build ## SSA backend test suite
	$(NIX_DEVELOP) bash ./scripts/tests/test_ssa.sh

.PHONY: test-ssa-lowering-scaling
test-ssa-lowering-scaling: build ## Bug 178: `match` lowering (Lower + SSAVerify + SSACleanup) scales <= n^1.3 in arms, measured by lower-stage heartbeats (and instructions:u where perf counts)
	$(NIX_DEVELOP) bash ./scripts/tests/check_ssa_lowering_scaling.sh

.PHONY: test-ssa-verify-agreement
test-ssa-verify-agreement: build ## SSAVerify behavior preservation (trust pass): valid complex CFGs still accepted + codegen correct; hard merge blocker for dominator/predecessor/use-def changes
	$(NIX_DEVELOP) bash ./scripts/tests/check_ssa_verify_agreement.sh

.PHONY: test-stackvm
test-stackvm: build ## P7 workload 10: stackvm assembler/codec/verifier/VM/disassembler byte-identical to an independent Python implementation (test, generated, mutated and corrupted programs), 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_stackvm_differential.sh

.PHONY: test-std-compiled-coverage
test-std-compiled-coverage: build ## Bug-039 class closure: one compiled+run behavioral fixture per public std module, fail-closed inventory
	$(NIX_DEVELOP) bash ./scripts/tests/check_std_compiled_coverage.sh

.PHONY: test-std-hardening
test-std-hardening: build ## Phase 7 item 0 (H1-H5): radix overflow->None, no additive bounds guards (lint), IO error honesty, non-Copy ordered traversal, strict base64 pads, unproven-content check
	$(NIX_DEVELOP) bash ./scripts/tests/check_std_hardening.sh

.PHONY: test-std-test
test-std-test: build ## P7 step 5: std.test discipline — expect_* silent/cap-free/alloc-free, assert_* Console-visible with stable messages, oracle sink path, no xUnit surface
	$(NIX_DEVELOP) bash ./scripts/tests/check_std_test.sh

.PHONY: test-stdlib-handoff
test-stdlib-handoff: ## Stdlib handoff gate: required Phase 5/6 surfaces stable/provisional, none blocked (Phase 6 #19)
	$(NIX_DEVELOP) bash ./scripts/tests/check_stdlib_handoff.sh

.PHONY: test-stdlib-manifest
test-stdlib-manifest: build ## P7 2a: five-fact manifest (allocates/ownership/fails/capability/proof-class) complete + signature-agreeing; 2b free-fn duplicate check
	$(NIX_DEVELOP) bash ./scripts/tests/check_stdlib_manifest.sh

.PHONY: test-string-char-at
test-string-char-at: build ## string_char_at differential gate: interp == compiled, byte-indexed, -1 OOB (audit 2026-07-16)
	$(NIX_DEVELOP) bash ./scripts/tests/check_string_char_at.sh

.PHONY: test-struct-layout
test-struct-layout: build ## Struct mixed-width field-layout regression gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_struct_field_layout.sh

.PHONY: test-struct-update
test-struct-update: build ## Struct functional-update gate: S { f: x, ..base } (Phase 6 #5)
	$(NIX_DEVELOP) bash ./scripts/tests/check_struct_update.sh

.PHONY: test-submodule-check
test-submodule-check: build ## Submodule-checking gate (KNOWN_HOLES H12): user sub-file bodies get the full front-end; std exemption stays disclosed
	$(NIX_DEVELOP) bash ./scripts/tests/check_submodule_check_coverage.sh

.PHONY: test-tar-list
test-tar-list: build ## P7 workload 4: tar_list byte-identical to tar -tf (size edges/prefix paths) + 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_tar_list_differential.sh

.PHONY: test-tcpserve
test-tcpserve: build ## P7 workload 8: single-connection server (TcpListener::accept) — READY/DONE discipline, injected bind/EOF failures, dribbling client, watchdog
	$(NIX_DEVELOP) bash ./scripts/tests/check_tcpserve.sh

.PHONY: test-totality-judgment
test-totality-judgment: build ## Totality matrix (Phase 6.5): trap/divergence facts (arith/bounds/branch) agree interp==compiled; a gate over the already-centralized facts
	$(NIX_DEVELOP) bash ./scripts/tests/check_totality_judgment.sh

.PHONY: test-trace-pipeline
test-trace-pipeline: build ## Phase 6C #3: `concrete <file> --trace-pipeline` per-stage JSON trace names the first failing phase (parse/resolve/check/…) for rejected programs; all-ok for accepted
	$(NIX_DEVELOP) bash ./scripts/tests/check_trace_pipeline.sh

.PHONY: test-trailing-value-blocks
test-trailing-value-blocks: build ## Trailing-value gate: if/match as value-block trailing values (interp==compiled); all-statement forms stay statements
	$(NIX_DEVELOP) bash ./scripts/tests/check_trailing_value_blocks.sh

.PHONY: test-type-agreement
test-type-agreement: build ## Type-agreement gate (Phase 6.5 #9): Check and Elab type source expressions through one shared TypeJudgment (E0228/E0715 red-team)
	$(NIX_DEVELOP) bash ./scripts/tests/check_type_agreement.sh

.PHONY: test-type-alias
test-type-alias: build ## Type-alias gate: transparency + no-new-identity + bad-form rejection (Phase 6 #3)
	$(NIX_DEVELOP) bash ./scripts/tests/check_type_alias.sh

.PHONY: test-v2-migration-plan
test-v2-migration-plan: build ## R-0004 package 3: the V1->V2 migration dry run reconciles and manufactures no freshness
	$(NIX_DEVELOP) bash ./scripts/tests/check_v2_migration_plan.sh

.PHONY: test-vc-bridge-register
test-vc-bridge-register: ## VC-bridge register gate (every obligation family has a row)
	$(NIX_DEVELOP) bash ./scripts/tests/check_vc_bridge_register.sh

.PHONY: test-vc-discharge-examples
test-vc-discharge-examples: build ## VC/discharge example matrix gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_vc_discharge_examples.sh

.PHONY: test-vc-examples
test-vc-examples: build ## End-of-Phase-2 VC/SMT examples gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_vc_examples.sh

.PHONY: test-vc-schema
test-vc-schema: build ## VC schema v1 gate
	$(NIX_DEVELOP) bash ./scripts/tests/check_vc_schema.sh

.PHONY: test-verify-gates
test-verify-gates: build ## Verification gate plumbing tests
	$(NIX_DEVELOP) bash ./scripts/tests/test_verify_gates.sh

.PHONY: test-wordfreq
test-wordfreq: build ## P7 workload 6: wordfreq byte-identical to C-locale tr|sort|uniq -c (real text + 200k scale + edges) + 13t exit codes
	$(NIX_DEVELOP) bash ./scripts/tests/check_wordfreq_differential.sh

.PHONY: test-workflow-yaml
test-workflow-yaml: ## Workflow-YAML gate: every .github/workflows/*.yml parses (no build needed)
	$(NIX_DEVELOP) bash ./scripts/tests/check_workflow_yaml.sh

.PHONY: test-wrapping-arith
test-wrapping-arith: build ## Wrapping-arith gate: wrapping_add/sub/mul wrap correctly (interp==compiled), integer-only (Phase 6 #10 Stage 2.1)
	$(NIX_DEVELOP) bash ./scripts/tests/check_wrapping_arith.sh

.PHONY: test-wrong-code
test-wrong-code: build ## Wrong-code detector tests
	$(NIX_DEVELOP) bash ./scripts/tests/test_wrong_code.sh
