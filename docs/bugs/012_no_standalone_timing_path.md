# Bug 012: No Easy Timing Path For Standalone Benchmark Programs

**Status:** Open (ergonomic/access gap)
**Discovered:** 2026-03-15
**Discovered in:** `examples/mal/main.con`

## Situation

| Layer | timing available? |
|-------|-------------------|
| Compiler builtin | **No** |
| Stdlib `std.time` | **Yes** — `Instant::now`, `elapsed`, `unix_timestamp`, `sleep` |
| Standalone `.con` files | **No easy path** — `import std.time` requires project/package setup |

## The Real Gap

Timing and benchmarking are blocked in standalone real programs for the same reason printing is awkward there: the usable API lives in stdlib/project setup rather than in an always-available surface.

For Phase H comparative workloads, this means:

- benchmark code cannot easily self-measure when compiled as a standalone `.con` file
- users fall back to external shell timing or ad hoc harnesses
- per-benchmark timing inside the program is harder than it should be

## What Is NOT the Problem

- Concrete does have a timing API in `std.time`
- project-based code with stdlib access can use it
- this is not "Concrete has no clock"

## Impact

- standalone benchmark examples cannot easily report their own timings
- Phase H comparison work must currently time programs externally
- the standalone/program split becomes visible in one more basic workflow

## Possible Fixes

- **Option A:** Add a tiny builtin timing surface for benchmarking-oriented standalone use
- **Option B:** Auto-resolve `std.*` imports in standalone mode so `std.time` is usable
- **Option C:** Keep timing external by design, but document that standalone programs are not expected to self-time

The most important thing is to make the intended workflow explicit and low-friction.
