# FixDock

Menu bar shell for a repair bench. Unofficial fork of [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils), GPL-3.0-or-later. Not affiliated with the original authors, and not an official release.

This build is the shell plus the first tool, the URL cleaner. It also has the menu bar icon, settings, the feature catalog, onboarding, the permission guide, shared controls, and one global shortcut. The other planned tools are names in the catalog only.

## English

FixDock is a lightweight macOS 14+ menu bar app for someone who repairs Macs. It is free, it is not sold, and it does not phone home. There is no account, no analytics, and no update check.

The planned tools, in the order they will be added:

1. URL cleaner
2. Quit and close protection
3. Cleaning mode
4. Text snippets
5. AirDrop auto-zip (new; not in the original project)
6. Cleaner
7. Screenshot
8. Screen recorder

URL cleaner is included. Installing it turns on clipboard cleaning the first time, and it can be switched off. Cleaning stays on this Mac. The other names in Settings only save a choice. The app does not ask for a permission for the URL cleaner. You can open the permission guide from Settings to see how a later tool will ask.

### License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE) (unchanged from upstream) and [NOTICE](NOTICE). Copyright in the original code is Vorssaint and the vorssaint-utils contributors, Copyright (C) 2026. FixDock keeps those headers. Upstream history is in this repository, imported at `1cdbd59b1c7dccd036ec1713b2ea048334990d06`.

The Vorssaint name, logo, and signing identity are not used. See [TRADEMARKS.md](TRADEMARKS.md).

### Build and run

The build has not been verified here. This checkout was prepared on Linux, which cannot compile a macOS Swift app. On a Mac with Xcode Command Line Tools:

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

Do not use the upstream signing identity. There is no notarization step and no update feed.

Remove FixDock without touching a Vorssaint install:

```bash
./Tools/uninstall.sh
```

Click the menu bar icon for the panel. The default shortcut is Control-Option-Command-F. Right-click the icon for Settings and Quit.

### What was removed

Audio and the mixer, the system monitor, fan control, the notch, window and Dock tools, the app switcher, mouse and scroll tools, Homebrew, app updates, the uninstaller, ports, wallpaper, agent usage, and the other upstream modules. Their source remains in git history at merge commit `7336fd329db673743444ce169c1373097be9765a`. Languages other than English and Korean were removed. Upstream brand images were removed. No third-party font was bundled upstream, and none is bundled here.

A future personal Homebrew tap is described in [docs/HOMEBREW.md](docs/HOMEBREW.md). The tap is not created yet.

## 한국어

FixDock은 수리 작업대에서 쓰는 가벼운 macOS 14+ 메뉴 막대 앱입니다. [vorssaint-utils](https://github.com/vorssaint/vorssaint-utils)를 수정한 비공식 포크이며, GPL-3.0-or-later입니다. 원작자와 관련이 없고, 공식 릴리스가 아닙니다. 판매하지 않습니다. 계정, 분석, 업데이트 확인이 없습니다.

이 빌드는 껍데기에 첫 도구인 링크 정리가 들어 있습니다. 메뉴 막대 아이콘, 설정, 기능 목록, 처음 실행 안내, 권한 안내, 공통 화면, 전역 단축키도 있습니다. 나머지 예정 도구는 목록의 이름만 있습니다.

나중에 이 순서로 넣을 도구:

1. 링크 정리
2. 종료·닫기 보호
3. 화면 정리 모드
4. 상용구
5. AirDrop 자동 압축 (원본에는 없는 새 기능)
6. Mac 정리
7. 스크린샷
8. 화면 녹화

링크 정리는 들어 있습니다. 처음 설치하면 클립보드 정리가 켜지고, 끌 수 있습니다. 정리는 이 Mac 안에서만 합니다. 나머지 이름은 선택만 저장합니다. 링크 정리는 권한을 요구하지 않습니다. 설정에서 권한 안내를 미리 열어볼 수 있습니다.

### 라이선스

GNU General Public License v3.0 이상. [LICENSE](LICENSE)는 업스트림 그대로입니다. [NOTICE](NOTICE)에 출처와 수정 내용이 있습니다. 원본 저작권은 Vorssaint 및 vorssaint-utils 기여자, Copyright (C) 2026입니다. 소스 헤더를 유지합니다. 업스트림 기록은 이 저장소에 있으며, 가져온 커밋은 `1cdbd59b1c7dccd036ec1713b2ea048334990d06`입니다.

Vorssaint 이름, 로고, 서명 신원은 쓰지 않습니다. [TRADEMARKS.md](TRADEMARKS.md)를 보세요.

### 빌드와 실행

이 빌드는 여기서 검증하지 않았습니다. Linux에서는 macOS Swift 앱을 컴파일할 수 없습니다. Xcode Command Line Tools가 있는 Mac에서:

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

업스트림 서명 신원은 쓰지 마세요. 공증과 업데이트 피드는 없습니다.

Vorssaint 설치는 건드리지 않고 FixDock만 지우려면:

```bash
./Tools/uninstall.sh
```

메뉴 막대 아이콘을 누르면 패널이 열립니다. 기본 단축키는 Control-Option-Command-F입니다. 아이콘을 오른쪽 클릭하면 설정과 종료가 나옵니다.

### 뺀 것

오디오와 믹서, 시스템 모니터, 팬 제어, 노치, 창과 Dock 도구, 앱 전환, 마우스와 스크롤, Homebrew, 앱 업데이트, 제거 도구, 포트, 배경화면, 에이전트 사용량, 그 밖의 업스트림 모듈을 뺐습니다. 소스는 머지 커밋 `7336fd329db673743444ce169c1373097be9765a`의 git 기록에 남아 있습니다. 영어와 한국어 외 언어를 뺐습니다. 업스트림 브랜드 이미지를 뺐습니다. 업스트림은 서드파티 글꼴을 넣지 않았고, 여기도 없습니다.

개인 Homebrew 탭은 [docs/HOMEBREW.md](docs/HOMEBREW.md)에 적어 두었습니다. 탭 저장소는 아직 만들지 않습니다.
