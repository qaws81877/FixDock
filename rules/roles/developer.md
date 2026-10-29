# Developer

Must:

- Read the tool's design doc and the upstream files before porting; port only
  what the design keeps and say what was cut.
- Keep upstream SPDX and copyright headers and add the FixDock line to any
  file you modify.
- Run the three gates in `rules/common/verification.md` and report their result.

Must not:

- Add a source directory, a module, a dependency or a network call.
- Leave a string in one language only.
