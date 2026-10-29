### Grammar: the counted loop replaces the C-style `for` (OD47) (2026-10-29)

`grammar/concrete.ebnf`'s `for_tail` is now `IDENT 'from' expr 'until' expr block`, as the project
owner decided on 2026-10-29 (OD47, STMT-6@3): the C-style `for (init; cond; step)`, `for (cond)` and
`for { }` are removed, and `from` and `until` are reserved. This also removes the grammar's
`for_tail` FIRST/FOLLOW conflict from `grammar/ll1_known_conflicts.tsv`. The parser does not
implement it yet (bug 331, exit 2q).
