# Bug 010: No String Substring Extraction Path

**Status:** Open (missing feature / stdlib gap)
**Discovered:** 2026-03-15
**Discovered in:** `examples/mal/main.con`

## Symptom

Concrete has string inspection helpers such as `string_length`, `string_char_at`, and `string_concat`, but no substring extraction path such as:

```con
string_substr(s: &String, start: Int, len: Int) -> String
```

This became a real blocker while implementing MAL's reader/symbol handling. Parser code naturally wants to slice the source string into token substrings, intern them, and move on.

## Current Workaround

Avoid constructing substrings entirely:

- compute symbol hashes directly from `(start, end)` source positions
- intern by `(hash, length)` instead of by a real substring value

This works, but it distorts normal parser structure and makes otherwise straightforward code harder to read.

## Impact

- parser/reader code cannot express normal substring-oriented logic directly
- Phase H interpreter/runtime workloads become more contorted than they should be
- pushes programs toward custom slice-hash logic instead of ordinary string processing

## Fix Direction

Provide one of:

- a builtin `string_substr(&String, start, len) -> String`
- a stdlib-owned substring helper with acceptable performance/ownership semantics
- a slice/string-view story if the project wants to avoid eager substring allocation

The main requirement is that parser code has a normal way to talk about substrings without re-implementing indexing logic everywhere.
