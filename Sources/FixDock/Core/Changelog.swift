// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 FixDock contributors

import Foundation

/// One release's changes, as its GitHub release notes list them. Items keep
/// inline Markdown (bold, code) for `ReleaseNotesText.inline`.
struct ChangelogEntry {
    let version: String
    /// yyyy-MM-dd, the day the release was published (UTC).
    let date: String
    let english: [String]
    let korean: [String]
}

/// Settings › Update log. Newest first. Every release adds its entry here in
/// both languages before it is tagged; `Tools/check-shell.py` fails when the
/// first entry is not the version in `Resources/Info.plist`.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.0.9", date: "2026-11-09",
            english: [
                "**The ⌘Q notice keeps working.** After FixDock had been running for a long time, the hold-to-quit notice could stop appearing at all. FixDock now resets it every time and shows it again if it did not reach the screen.",
                "**Korean snippet triggers.** Snippets with Korean triggers expand again while the Korean input source is on, alongside triggers made of Latin letters.",
            ],
            korean: [
                "**⌘Q 안내가 계속 잘 보입니다.** FixDock을 오래 켜 두면 길게 눌러 종료하라는 안내가 아예 안 보이게 될 수 있었습니다. 이제 띄울 때마다 상태를 새로 맞추고, 화면에 올라오지 않았으면 다시 띄웁니다.",
                "**한글 스니펫 트리거.** 한글로 등록한 스니펫 트리거가 한글 입력 상태에서 다시 펼쳐집니다. 영문 트리거도 함께 동작합니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.8", date: "2026-11-09",
            english: [
                "**Smaller phone videos.** The resolution levels in video compression now shrink iPhone videos at every level instead of re-encoding them at a fixed rate. You can also type the target size instead of only stepping it.",
                "**Snippets in Korean input.** Snippet triggers made of Latin letters now expand while the Korean input source is on, so you no longer need to switch to English first.",
                "**Quit notice diagnostics.** FixDock records in its diagnostics log whether the ⌘Q notice actually appeared, to track down Macs where it does not show.",
                "**Settings fits the sidebar.** Settings opens tall enough to show the whole sidebar.",
            ],
            korean: [
                "**휴대폰 영상이 더 작아집니다.** 영상 압축의 해상도 단계(높음·중간·낮음)가 아이폰 영상을 정해진 비율로 다시 인코딩하지 않고 모든 단계에서 줄입니다. 목표 크기는 버튼뿐 아니라 숫자로도 입력할 수 있습니다.",
                "**한글 입력에서도 스니펫.** 영문으로 된 스니펫 트리거가 한글 입력 상태에서도 펼쳐집니다. 먼저 영문으로 바꾸지 않아도 됩니다.",
                "**종료 안내 진단.** ⌘Q 안내가 실제로 화면에 떴는지 진단 기록에 남겨, 안내가 보이지 않는 Mac의 원인을 찾습니다.",
                "**설정 창이 사이드바에 맞춰 열립니다.** 설정을 열면 사이드바 전체가 보이는 높이로 열립니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.7", date: "2026-11-07",
            english: [
                "**Settings toolbar.** The sidebar button and Back/Forward now sit together right of the window buttons, with the current page's name beside them. Command-[ and Command-] go back and forward, Control-Command-S shows or hides the sidebar.",
                "**Search Settings.** Type in the field at the top of the sidebar to find a page or a setting on it, such as \"backup\" or \"microphone\". English words work in the Korean interface too. Choose a result to open its page.",
            ],
            korean: [
                "**설정 툴바.** 사이드바 버튼과 뒤로/앞으로 버튼이 창 버튼 오른쪽에 함께 있고, 그 옆에 현재 페이지 이름이 보입니다. Command-[와 Command-]로 뒤로/앞으로 가고, Control-Command-S로 사이드바를 보이거나 숨깁니다.",
                "**설정 검색.** 사이드바 맨 위 검색창에 입력하면 페이지와 그 안의 설정 항목(예: \"백업\", \"마이크\")을 찾습니다. 한국어 화면에서 영어로 검색해도 됩니다. 결과를 고르면 그 페이지가 열립니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.6", date: "2026-11-06",
            english: [
                "**Install from a disk image.** Download `FixDock-1.0.6.dmg` from the release, open it and drag FixDock onto Applications. Double-clicking FixDock inside the image also works: it offers to move itself into Applications (a copy already there goes to the Trash) and reopens from there.",
                "**Permission guide.** When a tool needs Device Control and Data Access, Screen & System Audio Recording or Full Disk Access, FixDock opens that page in System Settings with a card beside it. Drag the FixDock icon from the card into the list and switch it on. Permission names now match the System Settings on your Mac.",
                "**Settings reorganized.** Permissions is now a tab in Settings › Features. Above the tool list, a bar shows how many tools are installed, with Install all and Remove all beside it. Shortcut, About, Update log and Advanced moved into a new App category at the bottom of the sidebar.",
                "**Update log.** Settings › Update log lists what changed in each version.",
                "**Advanced.** Settings › Advanced can export FixDock's settings to a file and import them back (the current settings are saved first, then FixDock restarts). Remove all permissions resets every permission given to FixDock and restarts it.",
            ],
            korean: [
                "**디스크 이미지로 설치.** 릴리스에서 `FixDock-1.0.6.dmg`를 받아 열고 FixDock을 Applications로 드래그합니다. 이미지 안의 FixDock을 더블클릭해도 됩니다. 응용 프로그램 폴더로 스스로 옮길지 묻고(이미 있던 복사본은 휴지통으로 갑니다) 그 위치에서 다시 엽니다.",
                "**권한 안내.** 도구에 기기 제어 및 데이터 접근, 화면 및 시스템 오디오 녹음, 전체 디스크 접근 권한이 필요하면 시스템 설정의 해당 화면을 열고 옆에 안내 카드를 띄웁니다. 카드의 FixDock 아이콘을 목록으로 끌어다 놓고 켜면 됩니다. 권한 이름도 이 Mac의 시스템 설정과 같게 바뀌었습니다.",
                "**설정 정리.** 권한은 설정 › 기능의 탭으로 옮겼습니다. 도구 목록 위에 설치된 도구 수를 막대로 보여 주고, 옆에 모두 설치와 모두 제거 버튼이 있습니다. 단축키, 정보, 업데이트 로그, 고급은 사이드바 맨 아래 새 \"앱\" 카테고리로 옮겼습니다.",
                "**업데이트 로그.** 설정 › 업데이트 로그에서 버전별 변경사항을 볼 수 있습니다.",
                "**고급.** 설정 › 고급에서 FixDock 설정을 파일로 내보내고 다시 가져올 수 있습니다(가져오기 전에 지금 설정을 먼저 저장하고, 끝나면 다시 시작합니다). 모든 권한 제거는 FixDock에 준 권한을 모두 초기화하고 다시 시작합니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.5", date: "2026-11-04",
            english: [
                "**Clipboard history (new tool).** Install it from Settings › Features. Command-Shift-V opens what you copied earlier: text, pictures and files. A search field, a type menu (image, text, link, colour, file, email), a list grouped by day, and a preview with details (source app, kind, dimensions, size, path, when it was copied).",
                "**Paste it back.** Return pastes into the app you were in, Command-Return copies, ⌘K opens the actions (paste, copy, pin, show in Finder, delete), ⌘P opens the type menu, Option-P pins. Without Accessibility, Return copies and says so.",
                "**What is kept.** Pinned items stay. The rest is kept for 1, 7, 30 (default) or 90 days or forever, at most 1,000 items, and pictures up to 1 GB by default (250 MB, 5 GB or no limit in Settings). Files are kept as their location, not copied. Pictures over 50 MB or 64 megapixels are skipped.",
                "**What is not recorded.** Copies an app marks as secret or temporary, copies made in apps you exclude, and temporary files. Links are kept cleaned while the URL cleaner is on. The screenshot tool's copies are recorded with FixDock as their source.",
                "Command-Shift-V replaces \"Paste and Match Style\" while the tool is installed. Another app holding the same shortcut gets the key too.",
            ],
            korean: [
                "**클립보드 기록(새 도구).** 설정 › 기능에서 설치합니다. Command-Shift-V로 예전에 복사한 글, 그림, 파일을 엽니다. 검색창, 유형 메뉴(이미지, 텍스트, 링크, 색상, 파일, 이메일), 날짜별 목록, 미리보기와 정보(출처 앱, 종류, 치수, 크기, 경로, 복사한 시각)가 있습니다.",
                "**다시 붙여넣기.** Return은 쓰던 앱에 붙여넣고, Command-Return은 복사만 합니다. ⌘K는 동작 메뉴(붙여넣기, 복사, 고정, Finder에서 보기, 삭제), ⌘P는 유형 메뉴, Option-P는 고정입니다. 손쉬운 사용 권한이 없으면 Return은 복사만 하고 알려 줍니다.",
                "**보관.** 고정한 항목은 남습니다. 나머지는 1, 7, 30(기본), 90일 또는 계속 보관하고, 최대 1,000개, 그림은 기본 1 GB까지입니다(설정에서 250 MB, 5 GB, 제한 없음). 파일은 복사하지 않고 위치만 기억합니다. 50 MB나 6,400만 화소를 넘는 그림은 건너뜁니다.",
                "**기록하지 않는 것.** 앱이 비밀이나 임시로 표시한 복사, 제외한 앱에서 한 복사, 임시 파일입니다. 링크 정리가 켜져 있으면 정리된 링크로 남깁니다. 스크린샷 도구로 복사한 것은 출처 FixDock으로 기록됩니다.",
                "도구를 설치한 동안 Command-Shift-V는 \"서식 없이 붙여넣기\" 대신 이 창을 엽니다. 같은 단축키를 쓰는 다른 앱도 키를 함께 받습니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.4", date: "2026-11-03",
            english: [
                "**Screenshots stay on screen as pins.** Every capture is pinned where it was taken, at its own size. The corner preview card is gone. Drag to move, drag an edge to resize. A bar under the selected pin has Save (and Save As), Copy, Share, Extract Text, Edit, QR, a handle to drag the image into other apps, Settings and Close. While a pin is selected: ⌘S save, ⇧⌘S Save As, ⌘C copy, ⌘E edit, ⌘T extract text, ⌘W or Esc close. A new capture hides the previous pin, and closing the top one brings back the one under it. \"Show preview\" is now \"Pin the capture on screen\".",
                "**Pins on the right display.** A window captured on a second display is pinned on that display.",
                "**Capture sounds.** A short focus beep when a drag starts and a shutter when a window, area or whole screen is captured. They follow the system alert volume and sound effects output. Turn them off in Settings › Screen capture.",
                "**Snap to lines.** While you drag a capture area, its corners snap to nearby horizontal and vertical lines such as window edges and table rules. Turn it off in Settings › Screen capture.",
                "**Send feedback.** Feedback moved to Settings › General, with Bug and Features & Ideas tabs. Send posts the report to the FixDock developer; Copy keeps it on this Mac. Nothing is sent until you press Send. Details are in PRIVACY.md.",
            ],
            korean: [
                "**스크린샷이 핀으로 화면에 남습니다.** 캡처하면 찍은 자리에 원래 크기로 고정됩니다. 모서리 미리보기 카드는 없어졌습니다. 끌어서 옮기고, 가장자리를 끌어 크기를 바꿉니다. 선택한 핀 아래 막대에 저장(다른 이름으로 저장), 복사, 공유, 텍스트 추출, 편집, QR, 다른 앱으로 끌어 놓는 손잡이, 설정, 닫기가 있습니다. 핀을 선택한 동안 ⌘S 저장, ⇧⌘S 다른 이름으로 저장, ⌘C 복사, ⌘E 편집, ⌘T 텍스트 추출, ⌘W나 Esc로 닫습니다. 새로 캡처하면 이전 핀은 숨고, 맨 위 핀을 닫으면 아래 핀이 다시 나옵니다. \"캡처 후 미리보기 표시\"는 \"캡처를 화면에 고정\"으로 바뀌었습니다.",
                "**핀이 맞는 디스플레이에 뜹니다.** 두 번째 디스플레이에서 창을 캡처하면 그 디스플레이에 고정됩니다.",
                "**캡처 소리.** 드래그를 시작하면 짧은 초점음이, 창·영역·전체 화면을 캡처하면 셔터음이 납니다. 시스템 알림 볼륨과 사운드 효과 출력 장치를 따릅니다. 설정 › 화면 캡처에서 끌 수 있습니다.",
                "**선 맞춤.** 캡처 영역을 드래그할 때 모서리가 창 테두리나 표 선 같은 가까운 가로·세로선에 맞춰집니다. 설정 › 화면 캡처에서 끌 수 있습니다.",
                "**피드백 보내기.** 피드백이 설정 › 일반으로 옮겨졌고 버그, 기능 및 아이디어 탭이 생겼습니다. 보내기를 누르면 FixDock 개발자에게 전달되고, 복사는 이 Mac에만 남깁니다. 보내기를 누르기 전에는 아무것도 전송하지 않습니다. 자세한 내용은 PRIVACY.md에 있습니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.3", date: "2026-11-02",
            english: [
                "**New tool: fast Korean/English switch** (adapted from the gksdud project, MIT). Caps Lock switches the input source the moment you press it, without a wrong first letter. Install it from Settings › Features. While it is on, FixDock maps Caps Lock to F19 and points \"Select the previous input source\" at it. Both go back when you turn it off, quit or uninstall, and after a crash at the next launch.",
                "**Hold for Caps Lock.** Hold the key for half a second to switch to English and turn Caps Lock on or off (on by default).",
                "**Why no keys are heard.** While another app holds secure input (a password field, a sign-in window, Terminal's Secure Keyboard Entry), macOS hides typing from quit protection and text snippets. Their Settings pages now say so and name the app. A keyboard monitor macOS refuses to start is shown and retried.",
                "**Feedback.** Settings › About › Feedback… copies a note with a diagnostics report (versions, tools on, keyboard monitor state and recent events). Nothing is sent. Typed text and snippet contents are never included.",
                "**Screenshot preview toast.** Copy and Save show a short \"Copied!\" or \"Saved!\" at the bottom centre of the screen. Copy now copies again even after the automatic copy and keeps the preview open.",
                "**Editor tooltips.** Resting the pointer on a tool in the editor's left rail shows its name and key.",
            ],
            korean: [
                "**새 도구: 빠른 한/영 전환** (gksdud를 수정해 사용, MIT). Caps Lock을 누르는 순간 입력 소스가 바뀌어 첫 글자가 씹히지 않습니다. 설정 › 기능에서 설치합니다. 켜져 있는 동안 FixDock은 Caps Lock을 F19로 바꾸고 \"이전 입력 소스 선택\"을 그 키에 연결합니다. 끄거나 종료하거나 제거하면 둘 다 원래대로 돌아가고, 비정상 종료 뒤에는 다음 실행 때 돌려놓습니다.",
                "**길게 눌러 대문자 고정.** 키를 0.5초 누르고 있으면 영어로 바꾸고 대문자 고정을 켜거나 끕니다(기본으로 켜짐).",
                "**키가 안 들리는 이유 표시.** 다른 앱이 보안 입력을 쓰는 동안(비밀번호 칸, 로그인 창, 터미널의 보안 키보드 입력) macOS는 종료 보호와 상용구에 입력을 숨깁니다. 이제 두 도구의 설정 화면에 이 상태와 해당 앱 이름이 표시됩니다. macOS가 키보드 모니터 시작을 거부하면 표시하고 다시 시도합니다.",
                "**피드백.** 설정 › 정보 › 피드백…에서 메모와 진단 보고서(버전, 켜진 도구, 키보드 모니터 상태와 최근 이벤트)를 함께 복사합니다. 아무것도 전송하지 않으며 입력한 글자와 상용구 내용은 포함하지 않습니다.",
                "**스크린샷 미리보기 토스트.** 복사와 저장을 하면 화면 하단 중앙에 \"복사완료!\" 또는 \"저장완료!\"가 잠깐 뜹니다. 자동 복사가 된 뒤에도 복사를 다시 할 수 있고, 미리보기는 열린 채로 남습니다.",
                "**편집창 툴팁.** 편집창 왼쪽 도구 막대의 도구 위에 포인터를 잠시 올려 두면 도구 이름과 단축키가 표시됩니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.2", date: "2026-10-31",
            english: [
                "**Scrolling capture keeps up.** Frames now come from a live stream at up to 60 a second instead of a screenshot every 120 ms, so fast scrolling no longer skips frames.",
                "**Scrolling capture recovers.** After a skipped frame the capture carries on. Scrolling back up never adds rows twice, and going back to where it stopped leaves no hole.",
                "**Sidebars stay put.** A sidebar or other fixed panel inside the area no longer breaks the capture or repeats down the image. Below the first screen it is filled with its background colour.",
                "The frame and bar around the area no longer show up in the picture, and long captures use far less memory.",
                "**Loupe sizes.** In the capture overlay, Z steps through off, regular and large (Shift-Z steps back). Large shows 21 × 21 pixels with grid lines. The loupe is on when the overlay opens; Settings › Screen capture › Screenshot can start it off.",
                "**Crosshairs.** A cross marks the centre pixel in the loupe, and thin blue lines through the pointer replace the cursor while the overlay is up.",
                "**Colour format.** C and the loupe label use the format picked in the same Settings section: HEX, HEX without #, `rgb()` or `hsl()`.",
            ],
            korean: [
                "**스크롤 캡처가 빨라졌습니다.** 120ms마다 스크린샷을 찍던 방식 대신 초당 최대 60프레임의 실시간 스트림을 써서, 빠르게 스크롤해도 프레임을 건너뛰지 않습니다.",
                "**스크롤 캡처가 끊겨도 이어집니다.** 프레임을 하나 건너뛰어도 캡처가 계속 이어집니다. 위로 되돌렸다 내려도 같은 줄이 두 번 들어가지 않고, 멈췄던 곳으로 돌아가도 빈틈이 생기지 않습니다.",
                "**사이드바가 반복되지 않습니다.** 영역 안의 사이드바나 고정된 패널 때문에 캡처가 깨지거나 이미지에 반복해서 찍히지 않습니다. 첫 화면 아래로는 그 배경색으로 채웁니다.",
                "영역 둘레의 테두리와 바가 결과 이미지에 찍히지 않고, 긴 캡처도 메모리를 훨씬 적게 씁니다.",
                "**확대경 크기.** 캡처 화면에서 Z를 누르면 끔, 보통, 크게 순서로 바뀝니다(Shift-Z는 반대 방향). 크게는 21 × 21픽셀을 격자선과 함께 보여 줍니다. 캡처 화면을 열면 확대경이 켜져 있고, 설정 › 화면 캡처 › 스크린샷에서 꺼진 상태로 시작하게 할 수 있습니다.",
                "**십자선.** 확대경 가운데 픽셀에 십자 표시가 있고, 캡처 화면이 떠 있는 동안 포인터 대신 포인터를 지나는 가는 파란 선이 표시됩니다.",
                "**색상 형식.** C 키와 확대경 라벨이 같은 설정 항목에서 고른 형식을 씁니다. HEX, # 없는 HEX, `rgb()`, `hsl()` 중에서 고릅니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.1", date: "2026-10-31",
            english: [
                "**Updates:** FixDock now checks its own GitHub releases about once an hour and when you open the panel. When a new version is out, the menu bar icon gets a dot and the panel shows a banner. \"Download and install\" checks the download's size, SHA-256, signature and notarization, replaces the app in place and restarts it. If the new version does not start, the old one is put back.",
                "Only the notarized copy in `/Applications` updates itself. Other copies open the release page. Developer and self-built copies never check.",
                "Turn the check off in Settings › About. What is sent is in PRIVACY.md.",
                "**Homebrew:** `brew tap qaws81877/tap`, `brew trust qaws81877/tap`, then `brew install --cask fixdock`",
            ],
            korean: [
                "**업데이트:** FixDock이 약 한 시간마다, 그리고 패널을 열 때 GitHub에서 새 릴리스를 확인합니다. 새 버전이 있으면 메뉴 막대 아이콘에 점이 붙고 패널에 배너가 나옵니다. \"다운로드 후 설치\"를 누르면 크기, SHA-256, 서명, 공증을 확인한 뒤 앱을 그 자리에서 바꾸고 다시 시작합니다. 새 버전이 시작되지 않으면 이전 버전으로 되돌립니다.",
                "`/Applications`에 있는 공증된 복사본만 스스로 업데이트합니다. 다른 복사본은 릴리스 페이지를 엽니다.",
                "설정 › 정보에서 끌 수 있습니다. 보내는 내용은 PRIVACY.md에 있습니다.",
                "**Homebrew:** `brew tap qaws81877/tap`, `brew trust qaws81877/tap`, `brew install --cask fixdock` 순서로 실행합니다.",
            ]
        ),
        ChangelogEntry(
            version: "1.0.0", date: "2026-10-30",
            english: [
                "First public release. All nine tools are in; install the ones you want from Settings › Features.",
                "Quit and close protection: Command-Q and Command-W wait for a confirmation.",
                "Cleaning mode: the keyboard is locked until Escape is pressed five times.",
                "Text snippets: a typed trigger expands into saved text.",
                "Media: images and videos compressed beside the originals, one zip or separate files.",
                "AirDrop auto-zip: photos received by AirDrop are compressed and zipped, the originals go to the Trash.",
                "Cleaner: caches, logs, leftovers and backups reviewed by category and removed after a confirmation.",
                "Screenshot: capture overlay (Control-Option-Command-4), full screen (Control-Option-Command-3), last region, loupe, colour picker, scrolling capture, preview with pin, QR and text copy, and an editor.",
                "Screen recorder: region, window or display with countdown, pause, microphone and system audio, pointer and typing tracks, a preview, and an editor with trim, zoom, overlays and MP4 or GIF export.",
                "README and onboarding describe the tools and the permission each one uses.",
                "Signed with a Developer ID, the hardened runtime and a secure timestamp, and notarized.",
            ],
            korean: [
                "첫 공개 릴리스입니다. 아홉 가지 도구가 모두 들어 있으며, 설정 › 기능에서 원하는 도구만 설치합니다.",
                "종료·닫기 보호: Command-Q와 Command-W가 확인을 기다립니다.",
                "청소 모드: Escape를 다섯 번 누를 때까지 키보드를 잠급니다.",
                "상용구: 입력한 트리거가 저장해 둔 글로 바뀝니다.",
                "미디어: 이미지와 동영상을 원본 옆에 압축하고, zip 하나나 개별 파일로 만듭니다.",
                "AirDrop 자동 압축: AirDrop으로 받은 사진을 압축해 zip으로 묶고, 원본은 휴지통으로 보냅니다.",
                "Mac 정리: 캐시, 로그, 남은 파일, 백업을 항목별로 검토하고 확인한 뒤에 지웁니다.",
                "스크린샷: 캡처 화면(Control-Option-Command-4), 전체 화면(Control-Option-Command-3), 마지막 영역, 확대경, 색상 추출, 스크롤 캡처, 고정할 수 있는 미리보기, QR과 텍스트 복사, 편집기.",
                "화면 녹화: 영역·창·디스플레이 녹화와 카운트다운, 일시 정지, 마이크와 시스템 오디오, 포인터·입력 트랙, 미리보기, 그리고 다듬기·확대·오버레이와 MP4·GIF 내보내기를 갖춘 편집기.",
                "README와 온보딩에서 도구마다 쓰는 권한을 설명합니다.",
                "Developer ID, hardened runtime, 보안 타임스탬프로 서명하고 Apple 공증을 받았습니다.",
            ]
        ),
    ]
}
