### Bug 335: The layout and stack-depth reports panic on a project file that uses std's Bytes and report zero sizes (2026-10-30)

Filed open: `--report layout` and `--report stack-depth` on a project file whose types reach std's `Bytes` printed Lean PANIC lines, computed those sizes as 0 and exited 0 (class 11, silent). Contained: both reports now refuse with an error naming the type and exit 1 (check_stack_budget.sh leg 6). Builds are unaffected.
([bug 335](docs/bugs/335_the_layout_and_stack_depth_reports_panic_on_a_pr.md)).
