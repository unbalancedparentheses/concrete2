### Bug 334: Compiler ledger emitted_files is never written: --report compiler-ledger shows [] even after a build (2026-10-30)

Filed open: `concrete --report compiler-ledger` lists no emitted files even after a build, because nothing writes the list (class 11; structural owner: the compiler-ledger work). The dead-code baseline keeps the unused writer until the fix.
([bug 334](docs/bugs/334_compiler_ledger_emitted_files_is_never_written_r.md)).
