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
      devShells = forAllSystems ({ pkgs }:
        let
          base = with pkgs; [
            lean4
            clang
            llvmPackages.llvm  # provides lli for fast test execution
            z3                 # external SMT solver for the pre-existing solver_trusted path
            bash
            gnumake
            gnugrep
            coreutils
            # pyyaml so scripts/tests/check_workflow_yaml.sh can actually run: it
            # needs pyyaml or ruby and FAILS (rather than skips) without either, so
            # the gate was red in this shell for everyone.
            (python3.withPackages (ps: [ ps.pyyaml ]))
            rustc
            typst
            zola
          ];
        in {
          # Default shell stays light: the pre-existing toolchain only. The
          # second-kernel drivers (Rocq, Isabelle) are an opt-in spike and Isabelle
          # is a multi-GB closure, so they live in a separate shell — no contributor
          # pays for them unless they run `--report multi-kernel`.
          default = pkgs.mkShell { packages = base; };

          # `nix develop .#provers` — adds the independent second kernels.
          provers = pkgs.mkShell {
            packages = base ++ (with pkgs; [
              coq                # independent CIC kernel (coqc/lia)
              coqPackages.stdlib # Rocq 9.0 stdlib (ZArith, Lia) — split out of coq-core
              isabelle           # independent HOL kernel (presburger) — foundational independence
              # Certificate-replay toolchain (see docs/SMT_SOUNDNESS.md). Makes a
              # solver's PROOF checkable rather than its verdict merely corroborated.
              drat-trim          # DRAT/LRAT checker for bit-blasted (SAT) certificates
            ]);
            # No veriT/cvc5 here on purpose. Isabelle's nix package already bundles
            # `contrib/verit-2021.06.2-rmx-3`, registers it in etc/components, and sets
            # ISABELLE_VERIT — verified by running `smt (verit)` under plain
            # `nix shell nixpkgs#isabelle`, where it closes a linear goal oracle-free.
            # (`VERIT_SOLVER` is empty there, which is misleading: the component
            # variable Isabelle actually reads is ISABELLE_VERIT.) cvc5 likewise comes
            # via CVC5_SOLVER, and nothing in this repo invokes it directly.
          };
        });
    };
}
