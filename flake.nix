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
            python3
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
              # Certificate-replay toolchain (see docs/SMT_SOUNDNESS.md). These make a
              # solver's PROOF checkable rather than its verdict merely corroborated.
              veriT              # Alethe-proof-producing SMT solver for Isabelle's `smt` method
              cvc5               # Alethe-proof-producing SMT solver (newer than Isabelle's bundled one)
              drat-trim          # DRAT/LRAT checker for bit-blasted (SAT) certificates
            ]);
            # Isabelle locates SMT solvers through these. Its nix package ships z3
            # 4.4.0pre (the version its reconstruction supports) but NOT veriT, so
            # `smt (verit)` is unavailable unless we point it at one.
            shellHook = ''
              export VERIT_SOLVER="${pkgs.veriT}/bin/veriT"
              export ISABELLE_VERIT="${pkgs.veriT}/bin/veriT"
            '';
          };
        });
    };
}
