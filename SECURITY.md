# Security

FixDock is an unofficial fork. Report problems on this repository's issue tracker.

FixDock sends no analytics and has no crash reporter. Its one network use is the update check in [PRIVACY.md](PRIVACY.md): it reads FixDock's own GitHub releases and, when you choose to install, downloads the release zip, which must match GitHub's SHA-256 and be signed by FixDock's developer and notarized by Apple before it replaces the app. Anything else that talks to the network must say so in NOTICE and PRIVACY.md before it ships.

Known limit: the updater's checks do not protect against malware that already runs under your account. The helper that swaps in an update runs as you, so another process of yours can pause it right after it checked the downloaded copy, replace that copy, and kill it right after the swap, before the installed copy is checked again. Its own bytes then stay in /Applications. No user-space fix for this exists.

Do not report FixDock issues to the vorssaint-utils maintainers. Their security contact does not cover this fork.
