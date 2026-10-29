# Future Homebrew cask

This file describes a cask that does not exist yet. Do not create the tap as part of the shell.

The tap repository, when someone creates it later, is `qaws81877/homebrew-tap`:

https://github.com/qaws81877/homebrew-tap

It is a personal, unofficial tap. It is not a Vorssaint formula or cask, and it must not reuse that project's name, icon, or bundle id.

## English

FixDock is not sold. A cask is only a convenient install of a build the owner publishes from source. Until a GitHub release zip exists, install from source with `./build.sh --install`.

The cask should look like this. The `sha256` and the download URL stay as placeholders until the first release.

```ruby
cask "fixdock" do
  version "0.1.0"
  sha256 "REPLACE_WITH_THE_ZIP_SHA256"

  url "https://github.com/qaws81877/FixDock/releases/download/v#{version}/FixDock-#{version}.zip"
  name "FixDock"
  desc "Menu bar shell for a repair bench. Unofficial fork of vorssaint-utils."
  homepage "https://github.com/qaws81877/FixDock"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "FixDock.app"

  uninstall quit: "io.github.qaws81877.fixdock"

  zap trash: [
    "~/Library/Preferences/io.github.qaws81877.fixdock.plist",
    "~/Library/Saved Application State/io.github.qaws81877.fixdock.savedState",
    "~/Library/Caches/io.github.qaws81877.fixdock",
  ]

  caveats <<~EOS
    FixDock is an unofficial GPL-3.0-or-later fork of vorssaint-utils.
    It is not affiliated with the original authors.
    This cask is not notarized unless the release was signed with your own Apple ID.
  EOS
end
```

Later, on a Mac:

```bash
brew tap qaws81877/tap
brew install --cask qaws81877/tap/fixdock
```

`brew tap qaws81877/tap` reads `github.com/qaws81877/homebrew-tap`. The cask file in that repo would be `Casks/fixdock.rb`.

The zip must contain `FixDock.app` at the top. Build it with `./build.sh`, then zip `build/stage/FixDock.app`. Publish that zip as a GitHub release named `v0.1.0` before filling in `sha256`. `shasum -a 256 FixDock-0.1.0.zip` is the value.

Apple Silicon only, macOS 14 (Sonoma) or newer, matching `build.sh`.

## 한국어

이 문서는 아직 만들지 않은 cask를 설명합니다. 이 단계에서 탭 저장소를 만들지 않습니다.

나중에 만들 탭은 `qaws81877/homebrew-tap`입니다.

https://github.com/qaws81877/homebrew-tap

개인용 비공식 탭입니다. Vorssaint 이름, 아이콘, 번들 ID를 쓰면 안 됩니다.

릴리스 zip이 생기기 전에는 `./build.sh --install`로 소스에서 설치합니다. cask의 `sha256`과 다운로드 주소는 첫 릴리스 전까지 비워 둡니다. 위의 Ruby 예시를 그대로 쓰면 됩니다.

zip 맨 위에는 `FixDock.app`이 있어야 합니다. `./build.sh`로 만든 `build/stage/FixDock.app`을 압축하고, GitHub 릴리스 `v0.1.0`에 올린 다음 `shasum -a 256` 값을 cask에 넣습니다.

Apple Silicon, macOS 14 이상만 지원합니다.

탭을 만든 뒤에 설치하는 명령:

```bash
brew tap qaws81877/tap
brew install --cask qaws81877/tap/fixdock
```
