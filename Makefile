.PHONY: build test clean check-grammar

NIX_DEVELOP = XDG_CACHE_HOME=$(CURDIR)/.cache nix --extra-experimental-features "nix-command flakes" develop --command

build:
	$(NIX_DEVELOP) lake build

test: build
	$(NIX_DEVELOP) sh ./run_tests.sh

check-grammar:
	python3 scripts/check_ll1.py grammar/concrete.ebnf

clean:
	$(NIX_DEVELOP) lake clean
