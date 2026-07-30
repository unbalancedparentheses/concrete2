{
  description = "Concrete development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs { inherit system; };
          });
    in {
      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            lean4
            clang
            llvmPackages.llvm  # provides lli for fast test execution
            coq                # independent CIC kernel (coqc/lia) — a second-kernel driver
            coqPackages.stdlib # Rocq 9.0 stdlib (ZArith, Lia) — split out of coq-core
            isabelle           # independent HOL kernel (presburger) — foundational independence
            z3                 # external SMT solver for the solver_trusted path
            bash
            gnumake
            gnugrep
            coreutils
            python3
            rustc
            typst
            zola
          ];
        };
      });
    };
}
