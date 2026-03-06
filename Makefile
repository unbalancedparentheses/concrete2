.PHONY: build test clean

build:
	lake build

test: build
	./run_tests.sh

clean:
	lake clean
