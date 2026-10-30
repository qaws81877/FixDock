# Privacy

FixDock has no account, no analytics, no telemetry and no crash reporter. Its tools work on this Mac and send nothing anywhere.

FixDock uses the network for one thing: checking its own GitHub releases for a newer version, and downloading that version when you choose to install it.

## The update check

- **What is requested.** `https://api.github.com/repos/qaws81877/FixDock/releases/latest`, GitHub's public description of FixDock's newest release. Nothing about you or this Mac is in the request.
- **What GitHub sees.** What any web request shows: your IP address, the time, and the header `User-Agent: FixDock`. The version you run is not sent. There are no cookies and nothing is cached.
- **How often.** About once an hour, 6 seconds after launch, and when you open the menu bar panel if the last check is older than 15 minutes. "Check now" in Settings › About checks at once.
- **Turning it off.** Settings › About › "Check for updates automatically". With it off, FixDock connects only when you press "Check now" or choose "Check for Updates…".

## Downloading and installing

Nothing is downloaded until you click "Download and install". Then FixDock downloads `FixDock-<version>.zip` from the release on GitHub (the link redirects to GitHub's file host). Before anything is replaced, the app checks that the file has the size and SHA-256 that GitHub lists, that it holds only `FixDock.app`, that it is the version offered, and that it is signed by FixDock's developer and notarized by Apple. The new copy then replaces the old one in place and FixDock restarts. If the new version does not start, the old one is put back. The download is kept in FixDock's own folder in `~/Library/Application Support` and removed afterwards.

## Copies that never check

The developer build ("FixDock (Developer)"), ad-hoc and self-built copies, and copies signed by anyone else make no network request at all. A release copy outside `/Applications`, or one you cannot change, still checks and shows a new version, but its button opens the release page instead of installing.
