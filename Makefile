.PHONY: build test clean

NIX_DEVELOP = XDG_CACHE_HOME=$(CURDIR)/.cache nix --extra-experimental-features "nix-command flakes" develop --command

build:
	$(NIX_DEVELOP) lake build

test:
	$(NIX_DEVELOP) sh ./run_tests.sh

clean:
	$(NIX_DEVELOP) lake clean
