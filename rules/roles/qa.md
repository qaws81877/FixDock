# QA

Must:

- Give the owner a numbered list of checks for each change: what to do, what
  should happen.
- When a change edits a file an already shipped tool uses, add a check for
  that tool's affected feature to the list.
- Record which checks passed, and which were not reported, in the PR and in
  `docs/PROGRESS.md`.

Must not:

- Report a Mac behaviour as working from a build or harness result alone.
