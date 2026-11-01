# FixDock

Menu bar tools for a repair bench. Unofficial fork of [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later. Not affiliated with the original authors, and not an official release.

FixDock has ten tools. You install the ones you want from Settings › Features; nothing runs until it is installed.

## English

FixDock is a lightweight macOS 14+ menu bar app for someone who repairs Macs. It is free and it is not sold. There is no account and no analytics. Its only network use is checking its own GitHub releases for updates, which you can turn off (see Updates).

The tools:

1. URL cleaner: removes tracking parameters from copied links.
2. Quit and close protection: holds Command-Q and Command-W until you confirm.
3. Cleaning mode: locks the keyboard while you wipe it.
4. Text snippets: expands a typed trigger into saved text.
5. Media: compresses images and videos.
6. AirDrop auto-zip: compresses and zips photos received by AirDrop (new; not in the original project).
7. Cleaner: reviews and removes caches, logs, leftovers and backups.
8. Screenshot: capture overlay, full screen, scrolling capture, preview, pin and editor.
9. Screen recorder: records a region, window or display with sound, plus an editor (trim, zoom, overlays, MP4 and GIF).
10. Fast Korean/English switch: Caps Lock switches the input source the moment you press it, without a wrong first letter (adapted from gksdud, MIT; see NOTICE). Hold the key for half a second to switch to English and turn Caps Lock on or off.

Permissions are asked only when a tool needs them: Accessibility for quit protection, cleaning mode, text snippets and the fast Korean/English switch; Full Disk Access for the cleaner; Screen Recording for screenshot and the recorder. The recorder asks for the microphone, system audio and Accessibility only when you turn those options on. Everything the tools do stays on this Mac.

Global shortcuts: Control-Option-Command-F opens the panel. While Screenshot is installed, Control-Option-Command-4 opens the capture overlay (press 2 there to record) and Control-Option-Command-3 captures the full screen.

### Updates

FixDock checks its own GitHub releases about once an hour and when you open the panel. When a newer version is out, the menu bar icon gets a dot and the panel shows a banner. "Download and install" shows the release notes, downloads the release zip, checks its size, SHA-256, signature and notarization, replaces the app in place and restarts it. If the new version does not start, the old one is put back. Only the release copy in `/Applications` installs updates itself; other copies open the release page. Developer and self-built copies never check. Turn the check off in Settings › About. What is sent: [PRIVACY.md](PRIVACY.md).

### License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE) (unchanged from upstream) and [NOTICE](NOTICE). Copyright in the original code is Vorssaint and the vorssaint-utils contributors, Copyright (C) 2026. FixDock keeps those headers. Upstream history is in this repository, imported at `1cdbd59b1c7dccd036ec1713b2ea048334990d06`.

The Vorssaint name, logo, and signing identity are not used. See [TRADEMARKS.md](TRADEMARKS.md).

### Install

Requires macOS 14 or later on Apple Silicon.

- **Download:** get `FixDock-<version>.zip` from the [latest release](https://github.com/qaws81877/FixDock/releases/latest), unzip it, and move `FixDock.app` to `/Applications`. The app is signed with a Developer ID and notarized by Apple, so it opens without a warning.
- **Homebrew:**

  ```bash
  brew tap qaws81877/tap
  brew trust qaws81877/tap
  brew install --cask fixdock
  ```

  The cask comes from [qaws81877/homebrew-tap](https://github.com/qaws81877/homebrew-tap). Recent Homebrew loads casks from a third-party tap only after `brew trust`; if your Homebrew has no `trust` command, skip that line. FixDock updates itself in place, so `brew upgrade` skips it unless you pass `--greedy`.

Keep FixDock in `/Applications`: it updates itself only there, and the login item needs that path. Version 1.0.0 has no updater; install 1.0.1 or later once by hand.

### Build and run

Build on a Mac with Xcode Command Line Tools:

```bash
xcode-select --install

git clone https://github.com/qaws81877/FixDock.git
cd FixDock
chmod +x build.sh Tools/uninstall.sh
./build.sh
open build/stage/FixDock.app
```

Install into `/Applications` (needed for a stable login item):

```bash
./build.sh --install
open /Applications/FixDock.app
```

A second copy that can sit beside the release app:

```bash
./build.sh --dev
open "build/stage.noindex/FixDock (Developer).app"
```

The script builds Apple Silicon (`arm64`) only, same as upstream. It signs ad-hoc. To sign with your own identity:

```bash
FIXDOCK_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

With an identity the app is signed with the hardened runtime and a secure timestamp, so it can be notarized. `./Tools/notarize.sh` notarizes and staples `build/stage/FixDock.app` and writes `build/release/FixDock-<version>.zip`; it needs a notarytool keychain profile you store once in your own Terminal (see the script's header). Do not use the upstream signing identity. A self-signed copy checks for releases but never installs one; only the notarized release in `/Applications` updates in place. Publish a release as tag `v<version>` with the single asset `FixDock-<version>.zip`, created in one `gh release create` call; its notes are what the app shows before installing.

Remove FixDock without touching a Vorssaint install:

```bash
./Tools/uninstall.sh
```

Click the menu bar icon for the panel. The default shortcut is Control-Option-Command-F. Right-click the icon for Settings and Quit.

### What was removed

Audio and the mixer, the system monitor, fan control, the notch, window and Dock tools, the app switcher, mouse and scroll tools, Homebrew, app updates, the uninstaller, ports, wallpaper, agent usage, and the other upstream modules. Their source remains in git history at merge commit `7336fd329db673743444ce169c1373097be9765a`. Languages other than English and Korean were removed. Upstream brand images were removed. No third-party font was bundled upstream, and none is bundled here.

Homebrew: see Install.

## 한국어

FixDock은 수리 작업대에서 쓰는 가벼운 macOS 14+ 메뉴 막대 앱입니다. [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils)를 수정한 비공식 포크이며, GPL-3.0-or-later입니다. 원작자와 관련이 없고, 공식 릴리스가 아닙니다. 판매하지 않습니다. 계정과 분석이 없습니다. 네트워크는 GitHub에서 FixDock 업데이트를 확인할 때만 쓰며, 끌 수 있습니다(업데이트 참고).

도구는 10개입니다. 설정 › 기능에서 원하는 도구만 설치합니다. 설치하기 전에는 아무것도 동작하지 않습니다.

도구:

1. 링크 정리: 복사한 링크에서 추적 매개변수를 지웁니다.
2. 종료·닫기 보호: Command-Q와 Command-W를 확인할 때까지 붙잡습니다.
3. 청소 모드: 키보드를 닦는 동안 입력을 잠급니다.
4. 상용구: 입력한 단축어를 저장한 글로 바꿉니다.
5. 미디어: 이미지와 영상을 압축합니다.
6. AirDrop 자동 압축: AirDrop으로 받은 사진을 압축해 zip으로 묶습니다 (원본에는 없는 새 기능).
7. Mac 정리: 캐시, 로그, 남은 파일, 백업을 살펴보고 지웁니다.
8. 스크린샷: 캡처 오버레이, 전체 화면, 스크롤 캡처, 미리보기, 고정, 편집기.
9. 화면 녹화: 영역·창·디스플레이를 소리와 함께 녹화하고, 편집기(자르기, 확대, 오버레이, MP4·GIF)로 다듬습니다.
10. 빠른 한/영 전환: Caps Lock을 누르는 순간 입력 소스가 바뀌어 첫 글자가 씹히지 않습니다 (gksdud를 수정해 사용, MIT, NOTICE 참고). 키를 0.5초 누르고 있으면 영어로 바꾸고 대문자 고정을 켜거나 끕니다.

권한은 도구가 필요할 때만 요청합니다. 종료·닫기 보호, 청소 모드, 상용구, 빠른 한/영 전환은 손쉬운 사용, Mac 정리는 전체 디스크 접근, 스크린샷과 화면 녹화는 화면 기록 권한을 씁니다. 화면 녹화는 마이크, 시스템 소리, 손쉬운 사용을 해당 옵션을 켤 때만 요청합니다. 도구의 모든 처리는 이 Mac 안에서만 합니다.

전역 단축키: Control-Option-Command-F는 패널을 엽니다. 스크린샷을 설치하면 Control-Option-Command-4는 캡처 오버레이를 열고(여기서 2를 누르면 녹화), Control-Option-Command-3은 전체 화면을 캡처합니다.

### 업데이트

FixDock은 약 한 시간마다, 그리고 패널을 열 때 GitHub에서 자체 릴리스를 확인합니다. 새 버전이 있으면 메뉴 막대 아이콘에 점이 붙고 패널에 배너가 나옵니다. "다운로드 후 설치"를 누르면 릴리스 노트를 보여 준 뒤 릴리스 zip을 다운로드하고, 크기·SHA-256·서명·공증을 확인한 다음 앱을 그 자리에서 바꾸고 다시 시작합니다. 새 버전이 시작되지 않으면 이전 버전으로 되돌립니다. `/Applications`에 있는 릴리스 복사본만 스스로 업데이트하고, 다른 복사본은 릴리스 페이지를 엽니다. 개발자 빌드와 직접 빌드한 복사본은 확인하지 않습니다. 설정 › 정보에서 끌 수 있습니다. 보내는 내용: [PRIVACY.md](PRIVACY.md).

### 라이선스

GNU General Public License v3.0 이상. [LICENSE](LICENSE)는 업스트림 그대로입니다. [NOTICE](NOTICE)에 출처와 수정 내용이 있습니다. 원본 저작권은 Vorssaint 및 vorssaint-utils 기여자, Copyright (C) 2026입니다. 소스 헤더를 유지합니다. 업스트림 기록은 이 저장소에 있으며, 가져온 커밋은 `1cdbd59b1c7dccd036ec1713b2ea048334990d06`입니다.

Vorssaint 이름, 로고, 서명 신원은 쓰지 않습니다. [TRADEMARKS.md](TRADEMARKS.md)를 보세요.

### 설치

Apple Silicon Mac, macOS 14 이상이 필요합니다.

- **다운로드:** [최신 릴리스](https://github.com/qaws81877/FixDock/releases/latest)에서 `FixDock-<버전>.zip`을 받아 압축을 풀고, `FixDock.app`을 `/Applications`로 옮깁니다. Developer ID로 서명하고 Apple 공증을 받아 경고 없이 열립니다.
- **Homebrew:**

  ```bash
  brew tap qaws81877/tap
  brew trust qaws81877/tap
  brew install --cask fixdock
  ```

  cask는 [qaws81877/homebrew-tap](https://github.com/qaws81877/homebrew-tap)에 있습니다. 최신 Homebrew는 `brew trust`로 신뢰한 서드파티 tap의 cask만 불러옵니다. `trust` 명령이 없는 버전이면 그 줄은 건너뛰세요. FixDock은 스스로 업데이트하므로 `brew upgrade`는 `--greedy`를 주지 않으면 건너뜁니다.

FixDock은 `/Applications`에 두세요. 그 위치에서만 스스로 업데이트하고, 로그인 항목도 그 경로가 필요합니다. 1.0.0에는 업데이트 기능이 없으니 1.0.1 이상을 한 번은 직접 설치하세요.

### 빌드와 실행

Xcode Command Line Tools가 있는 Mac에서 빌드합니다:

```bash
xcode-select --install

git clone https://github.com/qaws81877/FixDock.git
cd FixDock
chmod +x build.sh Tools/uninstall.sh
./build.sh
open build/stage/FixDock.app
```

`/Applications`에 설치 (로그인 시 열기는 이곳에 있어야 안정적입니다):

```bash
./build.sh --install
open /Applications/FixDock.app
```

정식 앱과 나란히 두는 개발용 복사본:

```bash
./build.sh --dev
open "build/stage.noindex/FixDock (Developer).app"
```

Apple Silicon (`arm64`)만 빌드합니다. 서명은 ad-hoc입니다. 본인 신원으로 서명하려면:

```bash
FIXDOCK_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

신원을 주면 hardened runtime과 보안 타임스탬프로 서명해서 공증할 수 있습니다. `./Tools/notarize.sh`가 `build/stage/FixDock.app`을 공증·스테이플하고 `build/release/FixDock-<버전>.zip`을 만듭니다. notarytool 키체인 프로필이 필요하며, 본인 터미널에서 한 번 저장합니다(스크립트 머리말 참고). 업스트림 서명 신원은 쓰지 마세요. 직접 서명한 복사본은 릴리스를 확인만 하고 설치하지 않습니다. 공증된 릴리스를 `/Applications`에 두었을 때만 그 자리에서 업데이트합니다. 릴리스는 태그 `v<버전>`과 단일 자산 `FixDock-<버전>.zip`으로, `gh release create` 한 번에 만듭니다. 릴리스 노트는 앱이 설치 전에 보여 주는 내용입니다.

Vorssaint 설치는 건드리지 않고 FixDock만 지우려면:

```bash
./Tools/uninstall.sh
```

메뉴 막대 아이콘을 누르면 패널이 열립니다. 기본 단축키는 Control-Option-Command-F입니다. 아이콘을 오른쪽 클릭하면 설정과 종료가 나옵니다.

### 뺀 것

오디오와 믹서, 시스템 모니터, 팬 제어, 노치, 창과 Dock 도구, 앱 전환, 마우스와 스크롤, Homebrew, 앱 업데이트, 제거 도구, 포트, 배경화면, 에이전트 사용량, 그 밖의 업스트림 모듈을 뺐습니다. 소스는 머지 커밋 `7336fd329db673743444ce169c1373097be9765a`의 git 기록에 남아 있습니다. 영어와 한국어 외 언어를 뺐습니다. 업스트림 브랜드 이미지를 뺐습니다. 업스트림은 서드파티 글꼴을 넣지 않았고, 여기도 없습니다.

Homebrew: 설치를 보세요.
