.PHONY: build-identity
.PHONY: test-doc-links
.PHONY: test-coverage-baseline test-evidence-reproducibility test-atomic-flip-entrance test-attestation-manifest test-one-producer test-impl-manifest test-classification-freshness test-gate-vacuity build setup-hooks pre-push pre-push-full test test-full test-ci-gates test-fast-surface-gates test-fast-surface-gates-mutate test-trust-gate test-proof-gate test-axiom-inventory test-cap-poly-design test-callable-values test-returned-ref-provenance test-proven-violation test-mono-collision test-nested-field-write test-raw-ptr-to-local test-struct-layout test-codegen-execution test-codegen-differential test-ssa test-compile-scaling test-golden test-examples test-fuzz test-oracle test-wrong-code test-reducer-smoke test-bundle-smoke test-verify-gates test-assumptions test-multi-kernel test-bv-certificates test-vc-bridge-register test-policy test-catches test-snapshots test-prove-cli test-evidence-corpus test-pv-oracle test-cv-oracle test-fc-oracle test-ct-oracle test-hmac-oracle test-release-bundle test-showcase test-registry-retirement test-proof-namespace test-proof-patterns test-contract-negatives test-contract-stability test-phase1-contracts test-vc-schema test-proofkit-arith test-smt-path test-smt-policy test-smt-replay test-smt-negatives test-vc-discharge-examples test-smt-examples test-smt-redteam test-vc-examples test-fpf-oracle test-phase2-vc test-obligation-core test-scoped-collector test-call-site-migration test-bounds-migration test-div-migration test-overflow-migration test-assume-migration test-loop-migration test-contract-clause-migration test-proof-link-migration test-obligation-lowering test-discharge-adapters test-obligation-report-views test-contracts-ledger-parity test-docs-drift test-workflow-yaml test-module-visibility test-project-model test-concrete-test test-diagnostics-quality test-byte-view test-collections test-concrete-fmt test-loop-control test-type-alias test-pattern-ergonomics test-struct-update test-no-tuples test-nested-patterns test-numeric-literals test-lex-escapes test-mixed-width-binops test-trailing-value-blocks test-submodule-check test-cast-matrix test-defer test-ignored-result test-array-bounds test-linear-discard test-linear-nested-scope test-linear-conservation test-fuzz-differential test-no-macros test-phase6-redteam test-stdlib-handoff test-build-profiles test-iteration-protocol test-wrapping-arith test-saturating-arith test-checked-arith test-arith-redteam test-report-arithmetic test-memory-model test-float-cast test-operational-vc-autodischarge test-no-duplicate-walkers test-single-truth-source test-obligation-policy-views test-obligation-prove-views test-phase3-obligation-core test-obligation-redteam test-compiler-ledger test-rich-diagnostics test-partial-facts test-source-maps test-cli-plumbing test-cli-contract test-api-boundary test-backend-contracts clean check-grammar paper paper-ec papers docs-site docs-serve help

NIX_DEVELOP = XDG_CACHE_HOME=$(CURDIR)/.cache nix --extra-experimental-features "nix-command flakes" develop --command
# provers shell adds the opt-in second kernels (Rocq, Isabelle) for multi-kernel
NIX_DEVELOP_PROVERS = XDG_CACHE_HOME=$(CURDIR)/.cache nix --extra-experimental-features "nix-command flakes" develop .#provers --command

##@ Build

# THE BUILD IDENTITY IS REGENERATED BEFORE THE BUILD, not as a step someone remembers.
#
# It is a constant compiled INTO the binary that names the sources the binary was built from, so a
# manual regeneration step means the value lags its sources by however long it takes anyone to
# notice. It lagged across several commits, and every binary built in that window carried a constant
# describing a build that no longer matched — the false provenance the value exists to prevent.
#
# Regenerating first makes the constant a function of the tree being built rather than of when
# someone last ran a script. It is cheap (a hash over ~96 files) and idempotent, so a no-op build
# stays a no-op: the generator writes the same bytes and lake relinks nothing.
build: build-identity ## Build the compiler (lake build inside nix develop)
	$(NIX_DEVELOP) lake build

build-identity: ## Regenerate the embedded compiler build identity from the source inventory
	@bash scripts/gen/build_identity.sh

clean: ## Remove lake build artifacts
	$(NIX_DEVELOP) lake clean

##@ Core tests

test: build ## Main test suite (run_tests.sh)
	$(NIX_DEVELOP) sh ./scripts/tests/run_tests.sh

test-full: build ## Main test suite, full mode (run_tests.sh --full)
	$(NIX_DEVELOP) sh ./scripts/tests/run_tests.sh --full

setup-hooks: ## Install the versioned git hooks (one-time, per clone) — pre-push then gates every push automatically
	git config core.hooksPath .githooks
	@echo "hooks installed: .githooks (pre-push runs the CI gate set)"

pre-push: ## Run exactly what the pre-push hook runs (fast surface gates + gates for touched areas)
	@bash .githooks/pre-push

pre-push-full: ## The FULL CI gate set locally, in parallel (~20+ min). What the hook deliberately does not run.
	@CORES=$$( (sysctl -n hw.ncpu 2>/dev/null || nproc) || echo 4 ); \
	JOBS=$$(( CORES > 12 ? 12 : CORES )) $(MAKE) test-ci-gates

test-trust-gate: build ## Trust gate: correctness-contract sections only
	$(NIX_DEVELOP) sh ./scripts/tests/run_tests.sh --trust-gate

test-fuzz-differential: build ## Random interp-vs-compiled differential fuzzer smoke (Phase 14 #13). Loops re-enabled after H7 fix.
	$(NIX_DEVELOP) python3 ./scripts/tests/fuzz_differential.py --n 200 --seed 1 --depth 3
	$(NIX_DEVELOP) python3 ./scripts/tests/fuzz_differential.py --n 200 --seed 2 --depth 3
	$(NIX_DEVELOP) python3 ./scripts/tests/fuzz_differential.py --mode borrow --n 100 --seed 1 --depth 3

test-examples: build ## Example coverage manifest gate + every runnable example's output (native and interpreter)
	$(NIX_DEVELOP) bash ./scripts/tests/check_examples.sh
	$(NIX_DEVELOP) bash ./scripts/tests/check_example_outputs.sh

##@ Proof / obligation gates

test-proof-gate: build ## Proof evidence gate (extraction, registry, Lean kernel check)
	$(NIX_DEVELOP) bash ./scripts/ci/proof_gate.sh

test-docs-drift: build ## Docs-drift gate: present-tense docs reference only real artifacts (#44)
	$(NIX_DEVELOP) bash ./scripts/tests/check_docs_drift.sh
	$(NIX_DEVELOP) bash ./scripts/tests/check_doc_links.sh

##@ Fuzz / stress / oracles

test-pv-oracle: build ## parse_validate randomized oracle (seeds 0, 42, 999)
	$(NIX_DEVELOP) bash ./examples/parse_validate/oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/parse_validate/oracle/run_oracle.sh 42
	$(NIX_DEVELOP) bash ./examples/parse_validate/oracle/run_oracle.sh 999

test-cv-oracle: build ## crypto_verify randomized oracle (seeds 0, 42, 999)
	$(NIX_DEVELOP) bash ./examples/crypto_verify/oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/crypto_verify/oracle/run_oracle.sh 42
	$(NIX_DEVELOP) bash ./examples/crypto_verify/oracle/run_oracle.sh 999

test-fc-oracle: build ## fixed_capacity randomized oracle (seeds 0, 42, 999)
	$(NIX_DEVELOP) bash ./examples/fixed_capacity/oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/fixed_capacity/oracle/run_oracle.sh 42
	$(NIX_DEVELOP) bash ./examples/fixed_capacity/oracle/run_oracle.sh 999

test-ct-oracle: build ## constant_time_tag randomized oracle (seeds 0, 42, 999)
	$(NIX_DEVELOP) bash ./examples/constant_time_tag/oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/constant_time_tag/oracle/run_oracle.sh 42
	$(NIX_DEVELOP) bash ./examples/constant_time_tag/oracle/run_oracle.sh 999

test-hmac-oracle: build ## hmac_sha256 randomized oracle (seeds 0, 42, 999)
	$(NIX_DEVELOP) bash ./examples/hmac_sha256/oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/hmac_sha256/oracle/run_oracle.sh 42
	$(NIX_DEVELOP) bash ./examples/hmac_sha256/oracle/run_oracle.sh 999

test-fpf-oracle: build ## fixed_point_filter randomized oracle (seeds 0, 7)
	$(NIX_DEVELOP) bash ./examples/vc_suite/fixed_point_filter_oracle/run_oracle.sh 0
	$(NIX_DEVELOP) bash ./examples/vc_suite/fixed_point_filter_oracle/run_oracle.sh 7

##@ Reports / artifacts

paper: ## Build the main paper PDF (typst)
	$(NIX_DEVELOP) typst compile paper/main.typ paper/main.pdf

# Evidence-carrying workflow paper
paper-ec: ## Build the evidence-carrying workflow paper PDF (typst)
	$(NIX_DEVELOP) typst compile paper/evidence-carrying.typ paper/evidence-carrying.pdf

papers: paper paper-ec ## Build all paper PDFs

docs-site: ## Build the documentation site (zola); the spec pages are generated from docs/spec first
	python3 scripts/spec/spec.py site --out site/content/spec
	python3 scripts/gen/site_reference.py --out site/content/reference
	$(NIX_DEVELOP) zola --root site build

docs-serve: ## Serve the documentation site locally on port 18080
	python3 scripts/spec/spec.py site --out site/content/spec
	python3 scripts/gen/site_reference.py --out site/content/reference
	$(NIX_DEVELOP) zola --root site serve --interface 127.0.0.1 --port 18080

##@ Misc

check-grammar: ## Verify the grammar is LL(1) (three independent checkers must agree)
	$(NIX_DEVELOP) bash ./scripts/tests/check_grammar_ll1.sh

help: ## Show this help (targets grouped by category)
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-32s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# The gate targets: one per row of scripts/tests/gates.tsv with a make cell, generated by
# scripts/gen/gates.py (edit the manifest, then python3 scripts/gen/gates.py --write).
include mk/gates.mk
