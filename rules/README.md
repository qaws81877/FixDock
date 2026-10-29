# rules/

Project rules for FixDock. Read this file first, then open only the files the
task needs.

Load order:

1. `CLAUDE.md` (repository root; local, not committed): commands,
   architecture, the `Tools/check-shell.py` rules.
2. `rules/project/product.md`: what FixDock is and what must not change.
3. `rules/common/engineering.md`: what can be changed directly and what needs
   the owner first; where docs live.
4. `rules/common/verification.md`: the gates and what counts as proof.
5. `rules/roles/developer.md` or `rules/roles/qa.md` for the role you are in.

Feature designs are in `docs/*.md` (one per tool). `docs/PROGRESS.md` is
local only.

New rules come from a session only through `/update-revise-rules`.
