.PHONY: build test test-full test-ssa test-fuzz clean check-grammar paper

NIX_DEVELOP = XDG_CACHE_HOME=$(CURDIR)/.cache nix --extra-experimental-features "nix-command flakes" develop --command

build:
	$(NIX_DEVELOP) lake build

test: build
	$(NIX_DEVELOP) sh ./run_tests.sh

test-full: build
	$(NIX_DEVELOP) sh ./run_tests.sh --full

test-ssa: build
	$(NIX_DEVELOP) bash test_ssa.sh

test-fuzz: build
	$(NIX_DEVELOP) bash test_parser_fuzz.sh

check-grammar:
	$(NIX_DEVELOP) python3 scripts/check_ll1.py grammar/concrete.ebnf

paper:
	typst compile paper/main.typ paper/main.pdf

clean:
	$(NIX_DEVELOP) lake clean
