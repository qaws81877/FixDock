# FixDock

Menu bar tools for people who use a Mac in Korean. Unofficial fork of [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later. Not affiliated with the original authors, and not an official release.

FixDock has twelve tools. You install the ones you want from Settings › Features; nothing runs until it is installed.

## English

FixDock is a lightweight macOS 14+ menu bar app: a small, hand-picked set of tools for people who use a Mac in Korean and English. It is free and it is not sold. There is no account and no analytics. It uses the network only to check its own GitHub releases for updates, which you can turn off (see Updates), and to send feedback when you press Send (see PRIVACY.md).

The tools:

1. URL cleaner: removes tracking parameters from copied links, Naver's ad and NT parameters included.
2. Quit and close protection: holds Command-Q and Command-W until you confirm.
3. Cleaning mode: locks the keyboard while you wipe it.
4. Text snippets: expands a typed trigger into saved text.
5. Media: compresses images and videos. Files zipped together keep their names, Hangul included, stored so they read correctly on Windows.
6. AirDrop auto-zip: compresses and zips photos received by AirDrop (new; not in the original project).
7. Cleaner: reviews and removes caches, logs, leftovers and backups.
8. Screenshot: capture overlay, full screen, scrolling capture, captures pinned on screen with an action bar, capture sounds, snap to lines, and an editor.
9. Screen recorder: records a region, window or display with sound, plus an editor (trim, zoom, overlays, MP4 and GIF).
10. Fast Korean/English switch: Caps Lock switches the input source the moment you press it, without a wrong first letter (adapted from gksdud, MIT; see NOTICE). Hold the key for half a second to switch to English and turn Caps Lock on or off.
11. Clipboard history: Command-Shift-V opens what you copied earlier, text, pictures and files, with a search field, a type menu (image, text, link, colour, file, email), a list by day and a preview with details. Return pastes into the app you were in; ⌘K opens the actions, which also paste text as the other keyboard layout would have typed it (dkssud becomes 안녕, ㅗ디ㅣㅐ becomes hello). Pins stay, the rest is kept for the period you choose (30 days by default, at most 1,000 items, pictures up to 1 GB by default). Files are kept as their location, not copied. Passwords marked by their app and excluded apps are not recorded, and links are kept cleaned while the URL cleaner is on.
12. Korean/English auto-fix: a word typed on the wrong layout (dkssud for 안녕, ㅗ디ㅣㅐ for hello) is erased and typed in the right one when you press Space, Tab or Return after it. It judges with two bundled word lists on this Mac; what you type is not stored or sent. Words with digits, addresses and all-capital words are left alone, and it can be turned off per app.

Permissions are asked only when a tool needs them: Accessibility for quit protection, cleaning mode, text snippets, the fast Korean/English switch and the Korean/English auto-fix (clipboard history uses Accessibility only to paste, and copies instead without it); Full Disk Access for the cleaner; Screen Recording for screenshot and the recorder. The recorder asks for the microphone, system audio and Accessibility only when you turn those options on. Everything the tools do stays on this Mac.

Global shortcuts: Control-Option-Command-F opens the panel. While Screenshot is installed, Control-Option-Command-4 opens the capture overlay (press 2 there to record) and Control-Option-Command-3 captures the full screen. While Clipboard history is installed, Command-Shift-V opens it.

### Updates

FixDock checks its own GitHub releases about once an hour and when you open the panel. When a newer version is out, the menu bar icon gets a dot and the panel shows a banner. "Download and install" shows the release notes, downloads the release zip, checks its size, SHA-256, signature and notarization, replaces the app in place and restarts it. If the new version does not start, the old one is put back. Only the release copy in `/Applications` installs updates itself; other copies open the release page. Developer and self-built copies never check. Turn the check off in Settings › About. What is sent: [PRIVACY.md](PRIVACY.md).

### License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE) (unchanged from upstream) and [NOTICE](NOTICE). Copyright in the original code is Vorssaint and the vorssaint-utils contributors, Copyright (C) 2026. FixDock keeps those headers. Upstream history is in this repository, imported at `1cdbd59b1c7dccd036ec1713b2ea048334990d06`.

The Vorssaint name, logo, and signing identity are not used. See [TRADEMARKS.md](TRADEMARKS.md).

### Install

Requires macOS 14 or later on Apple Silicon.

- **Download:** get `FixDock-<version>.zip` from the [latest release](https://github.com/qaws81877/FixDock/releases/latest), unzip it, and move `FixDock.app` to `/Applications`. The app is signed with a Developer ID and notarized by Apple, so it opens without a warning.
- **Disk image:** download `FixDock-<version>.dmg` from the same release, open it and drag `FixDock` onto `Applications`. Double-clicking `FixDock` inside the image works too: it offers to move itself into `/Applications` (a copy already there goes to the Trash) and opens from there. That needs an account that can write to `/Applications`; on a standard account, drag it and enter an administrator's name and password.
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

With an identity the app is signed with the hardened runtime and a secure timestamp, so it can be notarized. `./Tools/notarize.sh` notarizes and staples `build/stage/FixDock.app` and writes `build/release/FixDock-<version>.zip`; it needs a notarytool keychain profile you store once in your own Terminal (see the script's header). Do not use the upstream signing identity. A self-signed copy never checks for releases or installs one; only the notarized release in `/Applications` updates in place. Publish a release as tag `v<version>` with two assets, `FixDock-<version>.zip` (the only one the updater reads) and `FixDock-<version>.dmg`, created in one `gh release create` call; its notes are what the app shows before installing. Before tagging, add the version's entry to `Sources/FixDock/Core/Changelog.swift` in English and Korean (Settings › Update log shows it); `Tools/check-shell.py` fails while the first entry is not the version in `Resources/Info.plist`. For handing FixDock out directly, `./Tools/notarize.sh` followed by `./Tools/make-dmg.sh` (with the same `FIXDOCK_CODESIGN_IDENTITY`) writes a signed, notarized and stapled `build/release/FixDock-<version>.dmg` with the drag-to-Applications layout, attached to the release beside the zip.

Remove FixDock without touching a Vorssaint install:

```bash
./Tools/uninstall.sh
```

Click the menu bar icon for the panel. The default shortcut is Control-Option-Command-F. Right-click the icon for Settings and Quit.

### What was removed

Audio and the mixer, the system monitor, fan control, the notch, window and Dock tools, the app switcher, mouse and scroll tools, Homebrew, app updates, the uninstaller, ports, wallpaper, agent usage, and the other upstream modules. Their source remains in git history at merge commit `7336fd329db673743444ce169c1373097be9765a`. Languages other than English and Korean were removed. Upstream brand images were removed. No third-party font was bundled upstream, and none is bundled here.

Homebrew: see Install.

## 한국어

FixDock은 한국어로 Mac을 쓰는 사람을 위해 고른 도구를 모은 가벼운 macOS 14+ 메뉴 막대 앱입니다. [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils)를 수정한 비공식 포크이며, GPL-3.0-or-later입니다. 원작자와 관련이 없고, 공식 릴리스가 아닙니다. 판매하지 않습니다. 계정과 분석이 없습니다. 네트워크는 GitHub에서 FixDock 업데이트를 확인할 때(끌 수 있음, 업데이트 참고)와 피드백에서 보내기를 누를 때(PRIVACY.md 참고)만 씁니다.

도구는 12개입니다. 설정 › 기능에서 원하는 도구만 설치합니다. 설치하기 전에는 아무것도 동작하지 않습니다.

도구:

1. 링크 정리: 복사한 링크에서 추적 매개변수를 지웁니다. 네이버 광고·NT 매개변수도 지웁니다.
2. 종료·닫기 보호: Command-Q와 Command-W를 확인할 때까지 붙잡습니다.
3. 청소 모드: 키보드를 닦는 동안 입력을 잠급니다.
4. 상용구: 입력한 단축어를 저장한 글로 바꿉니다.
5. 미디어: 이미지와 영상을 압축합니다. zip으로 묶을 때 한글 파일명을 그대로 두고, Windows에서도 깨지지 않게 저장합니다.
6. AirDrop 자동 압축: AirDrop으로 받은 사진을 압축해 zip으로 묶습니다 (원본에는 없는 새 기능).
7. Mac 정리: 캐시, 로그, 남은 파일, 백업을 살펴보고 지웁니다.
8. 스크린샷: 캡처 오버레이, 전체 화면, 스크롤 캡처, 동작 막대가 있는 화면 고정 핀, 캡처 소리, 선 맞춤, 편집기.
9. 화면 녹화: 영역·창·디스플레이를 소리와 함께 녹화하고, 편집기(자르기, 확대, 오버레이, MP4·GIF)로 다듬습니다.
10. 빠른 한/영 전환: Caps Lock을 누르는 순간 입력 소스가 바뀌어 첫 글자가 씹히지 않습니다 (gksdud를 수정해 사용, MIT, NOTICE 참고). 키를 0.5초 누르고 있으면 영어로 바꾸고 대문자 고정을 켜거나 끕니다.
11. 클립보드 기록: Command-Shift-V로 예전에 복사한 글, 그림, 파일을 엽니다. 검색창, 유형 메뉴(이미지, 텍스트, 링크, 색상, 파일, 이메일), 날짜별 목록, 미리보기와 정보가 있습니다. Return으로 쓰던 앱에 붙여넣고, ⌘K로 동작 메뉴를 엽니다. 동작 메뉴에서 한/영을 잘못 두고 친 글을 바꿔 붙여넣을 수 있습니다(dkssud → 안녕, ㅗ디ㅣㅐ → hello). 고정한 항목은 남고, 나머지는 정한 기간(기본 30일, 최대 1,000개, 그림은 기본 1 GB까지) 동안 보관합니다. 파일은 복사하지 않고 위치만 기억합니다. 앱이 비밀번호로 표시한 복사와 제외한 앱은 기록하지 않고, 링크 정리가 켜져 있으면 정리된 링크로 남깁니다.
12. 한/영 자동 교정: 자판을 잘못 두고 친 낱말(안녕을 dkssud로, hello를 ㅗ디ㅣㅐ로)을 스페이스, Tab, Return을 누르는 순간 지우고 맞는 글자로 다시 칩니다. 앱에 든 낱말 목록 두 개로 이 Mac 안에서 판단하며, 입력한 내용을 저장하거나 보내지 않습니다. 숫자가 든 낱말, 주소, 전부 대문자인 낱말은 그대로 두고, 앱별로 끌 수 있습니다.

권한은 도구가 필요할 때만 요청합니다. 종료·닫기 보호, 청소 모드, 상용구, 빠른 한/영 전환, 한/영 자동 교정은 손쉬운 사용(클립보드 기록은 붙여넣을 때만 쓰고, 없으면 복사만 합니다), Mac 정리는 전체 디스크 접근, 스크린샷과 화면 녹화는 화면 기록 권한을 씁니다. 화면 녹화는 마이크, 시스템 소리, 손쉬운 사용을 해당 옵션을 켤 때만 요청합니다. 도구의 모든 처리는 이 Mac 안에서만 합니다.

전역 단축키: Control-Option-Command-F는 패널을 엽니다. 스크린샷을 설치하면 Control-Option-Command-4는 캡처 오버레이를 열고(여기서 2를 누르면 녹화), Control-Option-Command-3은 전체 화면을 캡처합니다. 클립보드 기록을 설치하면 Command-Shift-V로 엽니다.

### 업데이트

FixDock은 약 한 시간마다, 그리고 패널을 열 때 GitHub에서 자체 릴리스를 확인합니다. 새 버전이 있으면 메뉴 막대 아이콘에 점이 붙고 패널에 배너가 나옵니다. "다운로드 후 설치"를 누르면 릴리스 노트를 보여 준 뒤 릴리스 zip을 다운로드하고, 크기·SHA-256·서명·공증을 확인한 다음 앱을 그 자리에서 바꾸고 다시 시작합니다. 새 버전이 시작되지 않으면 이전 버전으로 되돌립니다. `/Applications`에 있는 릴리스 복사본만 스스로 업데이트하고, 다른 복사본은 릴리스 페이지를 엽니다. 개발자 빌드와 직접 빌드한 복사본은 확인하지 않습니다. 설정 › 정보에서 끌 수 있습니다. 보내는 내용: [PRIVACY.md](PRIVACY.md).

### 라이선스

GNU General Public License v3.0 이상. [LICENSE](LICENSE)는 업스트림 그대로입니다. [NOTICE](NOTICE)에 출처와 수정 내용이 있습니다. 원본 저작권은 Vorssaint 및 vorssaint-utils 기여자, Copyright (C) 2026입니다. 소스 헤더를 유지합니다. 업스트림 기록은 이 저장소에 있으며, 가져온 커밋은 `1cdbd59b1c7dccd036ec1713b2ea048334990d06`입니다.

Vorssaint 이름, 로고, 서명 신원은 쓰지 않습니다. [TRADEMARKS.md](TRADEMARKS.md)를 보세요.

### 설치

Apple Silicon Mac, macOS 14 이상이 필요합니다.

- **다운로드:** [최신 릴리스](https://github.com/qaws81877/FixDock/releases/latest)에서 `FixDock-<버전>.zip`을 받아 압축을 풀고, `FixDock.app`을 `/Applications`로 옮깁니다. Developer ID로 서명하고 Apple 공증을 받아 경고 없이 열립니다.
- **디스크 이미지:** 같은 릴리스에서 `FixDock-<버전>.dmg`를 받아 열고 `FixDock`을 `Applications`로 드래그합니다. 이미지 안의 `FixDock`을 더블클릭해도 됩니다. `/Applications`로 스스로 옮길지 묻고(이미 있던 복사본은 휴지통으로 갑니다) 그 위치에서 다시 엽니다. `/Applications`에 쓸 수 있는 계정이어야 하며, 일반 계정이면 드래그한 뒤 관리자 이름과 암호를 입력하세요.
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

신원을 주면 hardened runtime과 보안 타임스탬프로 서명해서 공증할 수 있습니다. `./Tools/notarize.sh`가 `build/stage/FixDock.app`을 공증·스테이플하고 `build/release/FixDock-<버전>.zip`을 만듭니다. notarytool 키체인 프로필이 필요하며, 본인 터미널에서 한 번 저장합니다(스크립트 머리말 참고). 업스트림 서명 신원은 쓰지 마세요. 직접 서명한 복사본은 릴리스를 확인하지도 설치하지도 않습니다. 공증된 릴리스를 `/Applications`에 두었을 때만 그 자리에서 업데이트합니다. 릴리스는 태그 `v<버전>`과 두 자산, `FixDock-<버전>.zip`(업데이트 기능이 읽는 유일한 파일)과 `FixDock-<버전>.dmg`로 `gh release create` 한 번에 만듭니다. 릴리스 노트는 앱이 설치 전에 보여 주는 내용입니다. 태그를 만들기 전에 그 버전의 항목을 `Sources/FixDock/Core/Changelog.swift`에 영어와 한국어로 추가합니다(설정 › 업데이트 로그에 표시됩니다). 첫 항목이 `Resources/Info.plist`의 버전과 다르면 `Tools/check-shell.py`가 실패합니다. 직접 나눠 줄 때는 `./Tools/notarize.sh` 다음에 같은 `FIXDOCK_CODESIGN_IDENTITY`로 `./Tools/make-dmg.sh`를 실행하면, 드래그 설치 배치로 서명·공증·스테이플한 `build/release/FixDock-<버전>.dmg`가 만들어집니다. 이 이미지는 릴리스에 zip과 함께 올립니다.

Vorssaint 설치는 건드리지 않고 FixDock만 지우려면:

```bash
./Tools/uninstall.sh
```

메뉴 막대 아이콘을 누르면 패널이 열립니다. 기본 단축키는 Control-Option-Command-F입니다. 아이콘을 오른쪽 클릭하면 설정과 종료가 나옵니다.

### 뺀 것

오디오와 믹서, 시스템 모니터, 팬 제어, 노치, 창과 Dock 도구, 앱 전환, 마우스와 스크롤, Homebrew, 앱 업데이트, 제거 도구, 포트, 배경화면, 에이전트 사용량, 그 밖의 업스트림 모듈을 뺐습니다. 소스는 머지 커밋 `7336fd329db673743444ce169c1373097be9765a`의 git 기록에 남아 있습니다. 영어와 한국어 외 언어를 뺐습니다. 업스트림 브랜드 이미지를 뺐습니다. 업스트림은 서드파티 글꼴을 넣지 않았고, 여기도 없습니다.

Homebrew: 설치를 보세요.
