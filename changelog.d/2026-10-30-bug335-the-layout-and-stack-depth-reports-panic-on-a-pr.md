### Bug 335: The layout and stack-depth reports panic on a project file that uses std's Bytes and report zero sizes (2026-10-30)

Filed open: `--report layout` and `--report stack-depth` on a project file whose types reach std's `Bytes` print Lean PANIC lines, compute those sizes as 0 and exit 0 (class 11). Builds are unaffected.
([bug 335](docs/bugs/335_the_layout_and_stack_depth_reports_panic_on_a_pr.md)).
