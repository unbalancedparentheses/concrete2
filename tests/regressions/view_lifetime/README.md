# View lifetime regression inputs

R-0483: open stdlib lifetime defect. These are the saved investigation sources,
retained together on 2026-09-15. They are not yet an automated passing safety gate.

| Project | Purpose | Reported observation |
|---|---|---|
| `control` | Read ByteCursor before consuming Bytes | Compiles; exits 65 ('A') |
| `use_after_free` | Consume Bytes, then read ByteCursor | Compiles; observed exit 0 through Ok |
| `unsafe_boundary` | User-defined pointer view without trusted/Unsafe | Rejected with E0521 |

Both cursor programs allocate capacity eight and push two bytes. The cursor stores
length two. `destroy(b)` frees the backing allocation; the subsequent cursor read
uses the retained pointer. The bounds check does not establish allocation lifetime.
The use-after-free byte is undefined: do not assert exit zero, a changed byte, or a
crash as the safety oracle. Even an observed 65 would not make that ordering safe.

To replay, build the repository compiler, then run `concrete build` from each project
directory. The first two currently produce binaries named `ctl` and `uaf`; record
their exit statuses separately from compiler success. The third must reject for
the missing Unsafe requirement. The observations above come from the supplied
investigation, not an independent replay performed when retaining these files.

At repair time, wire the control and negative case into the normal test gates:
valid access must still work and retained access after owner destruction must be
rejected or rendered safe by the new API. Preserve this original pair as historical
reproduction inputs if signatures change; a missing API alone is not a lifetime
regression test. Keep positive coverage for the replacement API and the Unsafe
negative control. Split cast and dereference probes if first-error diagnostics mask
one another. Text, ByteView accessors, reallocation and content mutation still need
their own tests; this pair does not establish their status.
