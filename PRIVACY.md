# Privacy

FixDock has no account, no analytics, no telemetry and no crash reporter. Its tools work on this Mac and send nothing anywhere.

FixDock uses the network for two things: checking its own GitHub releases for a newer version (and downloading it when you choose to install it), and sending feedback when you press Send.

## What the typing tools read

Text snippets and the Korean/English auto-fix watch the keys you type in other apps, which is what the Accessibility permission is for. They hold the word being typed in memory to decide whether it is a snippet trigger or a word typed on the wrong layout, and forget it at the next space, click or app switch. Nothing typed is written to disk or sent anywhere, and nothing is read while macOS has secure input on (password fields). The auto-fix judges with two word lists bundled in the app.

## The update check

- **What is requested.** `https://api.github.com/repos/qaws81877/FixDock/releases/latest`, GitHub's public description of FixDock's newest release. Nothing about you or this Mac is in the request.
- **What GitHub sees.** What any web request shows: your IP address, the time, and the header `User-Agent: FixDock`. The version you run is not sent. There are no cookies and nothing is cached.
- **How often.** About once an hour, 6 seconds after launch, and when you open the menu bar panel if the last check is older than 15 minutes. "Check now" in Settings › About checks at once.
- **Turning it off.** Settings › About › "Check for updates automatically". With it off, FixDock connects only when you press "Check now" or choose "Check for Updates…".

## Downloading and installing

Nothing is downloaded until you click "Download and install". Then FixDock downloads `FixDock-<version>.zip` from the release on GitHub (the link redirects to GitHub's file host). Before anything is replaced, the app checks that the file has the size and SHA-256 that GitHub lists, that it holds only `FixDock.app`, that it is the version offered, and that it is signed by FixDock's developer and notarized by Apple. The new copy then replaces the old one in place and FixDock restarts. If the new version does not start, the old one is put back. The download is kept in FixDock's own folder in `~/Library/Application Support` and removed afterwards.

## Feedback

Nothing is sent until you press **Send** in Settings › General › Feedback. Then FixDock posts the text shown in the sheet to `https://fixdock-feedback.answlals1236.workers.dev`, a small relay run by FixDock's developer on Cloudflare, which forwards it to the developer's Discord.

- **Bug.** Your note plus the report shown under "What will be sent": app and macOS versions, Mac model, language, which tools are on, Accessibility state, and recent keyboard monitor events. No typed text, no snippet contents, no clipboard.
- **Features & Ideas.** Your text, plus versions, Mac model and language only when "Include technical info" is checked.
- **What Cloudflare and Discord see.** Your IP address reaches Cloudflare, which uses it only to limit how often one address can send. The relay does not pass it on or store it; Discord receives only the text above.
- **Copy instead.** "Copy" puts the same text on the clipboard and sends nothing.

## Copies that never check

The developer build ("FixDock (Developer)"), ad-hoc and self-built copies, and copies signed by anyone else make no network request at all. A release copy outside `/Applications`, or one you cannot change, still checks and shows a new version, but its button opens the release page instead of installing.
