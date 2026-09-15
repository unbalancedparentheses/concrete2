# View lifetime regression inputs

R-0483: open stdlib lifetime defect. These are the saved investigation sources,
retained together on 2026-09-15. They are not yet an automated passing safety gate.

| Project | Purpose | Observation |
|---|---|---|
| `control` | Read ByteCursor before consuming Bytes | Compiles; exits 65 ('A') |
| `use_after_free` | Consume Bytes, then read ByteCursor | Compiles; observed exit 0 through Ok |
| `unsafe_boundary` | User-defined pointer view without trusted/Unsafe | Rejected with E0521 |
| `text_use_after_free` | Drop String, then read Text | Accepted (check rc 0) |
| `byteview_cursor_use_after_free` | Destroy Bytes, then read `ByteView::cursor` result | Accepted (check rc 0) |
| `byteview_try_text_use_after_free` | Destroy Bytes, then read `ByteView::try_text` result | Accepted (check rc 0) |
| `byteview_byte_rejected` | Destroy Bytes, then call `ByteView::byte(&b, _)` | **Rejected with E0205** |

The first three rows are the original 2026-09-15 investigation; the last four were
added when Text and ByteView coverage was extended, and each was checked directly.

**The classification these establish.** Two defect classes and one sound design:

- *Representation* — `ByteCursor` and `Text` store a `*const u8` taken from a
  borrow, so the value outlives the borrow by construction.
- *Conversion* — `ByteView` itself stores only `off`/`len`/`buf_len` and is sound,
  but `cursor` and `try_text` extract a raw pointer and hand back a value of the
  representation class, which gives the advantage back.
- *Sound* — `ByteView::byte(&self, buf: &Bytes, i)` demands the buffer on every
  access and validates `describes(buf)`. Destroy-then-read cannot be written: the
  owner is gone, so the call does not typecheck. This is the positive control for
  the repair direction, not merely a negative result.

Accept/reject here is a **compile-time** observation and is the reliable signal.
The use-after-free byte is undefined: do not assert exit zero, a changed byte, or a
crash as the safety oracle. Even an observed 65 would not make that ordering safe.
The cursor programs allocate capacity eight and push two bytes; the cursor stores
length two. `destroy(b)` frees the backing allocation and the later read uses the
retained pointer. The bounds check does not establish allocation lifetime.

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
one another.

Still uncovered: reallocation (a `push` that grows the buffer while a view is held),
content mutation under a validated `Text`, and the `buf_len` brand's behaviour against
a same-length wrong buffer. `describes` compares a length, and length equality is not
buffer identity — `byteview_byte_rejected` shows the accessor demands *an* owner, not
that it demands the *right* one.
