# Android Monitor

A native macOS app (SwiftUI) for mirroring, controlling and inspecting Android phones over USB or Wi‑Fi, with basic iPhone / iPad support. Android is built on `adb`; iOS uses Apple's own tooling. Nothing is installed on the phone.

<p align="center">
  <img src="docs/screenshots/files.png" alt="Mirror and file browser" width="100%">
</p>

| Apps with icons | Colored logcat with filters |
|---|---|
| <img src="docs/screenshots/apps.png" alt="Apps grid"> | <img src="docs/screenshots/logcat.png" alt="Logcat"> |

*Screenshots use sample data.*

## Features

**Mirror and control**
- Live screen mirror (H.264 via `screenrecord`, decoded with VideoToolbox / `AVSampleBufferDisplayLayer`)
- Mouse click, drag-to-swipe, scroll wheel / trackpad scrolling; right click = Back, middle click = Home
- Keyboard typing and special keys (Enter, Delete, Tab, arrows, Esc = Back)
- Clipboard: ⌘V / ⌘C / ⌘X / ⌘A act on the phone, and anything copied on the phone is synced to the Mac (text, full Unicode)
- Back / Home / Recents / Power buttons, screenshot, screen recording
- The stream pauses automatically when the window is hidden or the app has been inactive for 5 seconds; a toggle turns the mirror off entirely to save memory

**Files**
- Folder browser with size and date, quick links (Internal, Download, DCIM, …)
- Upload (including drag and drop), download, rename, delete, new folder
- Open text files in an editor and save them back to the device

**Apps**
- Grid with real app icons, search, and User / System / Debuggable filters
- Launch, force stop, app info, clear data, uninstall, install APK, save APK

**Logcat**
- Colored by priority, search with highlighting, tag and level filters, pause, clear, save
- Streams only while the tab is visible; buffers are capped and trimmed under memory pressure

**iPhone / iPad** (view and manage; Apple does not allow remote control)
- iPhones and iPads appear in the same sidebar when connected
- Live screen (view-only), the same feed QuickTime uses; needs Camera permission
- Screenshot (save or copy to clipboard) and screen recording
- Two-way text clipboard sync with the Mac (toggle in the header; uses `devicectl device pasteboard sync-with-host`)
- Apps: list (user apps by default), launch, uninstall, install `.ipa` (drag and drop or button); needs Developer Mode on the device
- Device info
- Needs Xcode 15+ on the Mac (`devicectl`) and iOS 17+ on the device; the device must be unlocked and trusted

**More**
- Shell, device information, Data explorer with Normal / Debuggable (`run-as`) / Root (`su`, only after confirmation) access
- Multiple devices in the sidebar, one active at a time
- Wi‑Fi connection: switch a USB phone to Wi‑Fi, QR pairing, pairing code, or connect by IP

## Download

Grab `AndroidMonitor.dmg` from the [Releases](../../releases) page, open it and drag **Android Monitor** to Applications.

- **Not notarized.** The app is not notarized (there is no paid Apple Developer account behind it), so macOS blocks the first launch. Either right-click the app → **Open** → **Open**, or run:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Android Monitor.app"
  ```

- **Apple Silicon and macOS 14 or newer only.**
- Google's `adb` (Apache 2.0) is bundled inside the app; see [NOTICE](NOTICE).

## Requirements (to build from source)

- macOS 14 or newer, Apple Silicon
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Android platform-tools, or internet access so the build can download them
- On the phone: Developer options → USB debugging

## Build and run

```bash
cd AndroidMonitor
./Scripts/build-release.sh      # fetches adb, generates the Xcode project, builds dist/Android Monitor.app
open "dist/Android Monitor.app"
```

The build is ad-hoc signed for local use. Distribution (Developer ID signing, notarization, DMG) is not set up yet; see `Scripts/create-dmg.sh`.

## Connecting a phone

| Method | Steps |
|---|---|
| USB | Plug in, accept the RSA prompt on the phone |
| USB → Wi‑Fi | Pair over Wi‑Fi → *Via USB* → *Switch USB phone to Wi‑Fi* (phone and Mac on the same network) |
| QR code | Phone: Wireless debugging → *Pair device with QR code*, scan the code shown by the app |
| Pairing code | Phone: *Pair device with pairing code*; pick the phone in the app and type the code |
| IP | Enter IP and port from the Wireless debugging screen |

QR and pairing-code discovery use mDNS (`adb mdns`). Some office or VPN networks block it; use the USB switch or the manual IP fields there.

## Releases

Releases are automatic. Every push to `main` is checked against its [Conventional Commit](https://www.conventionalcommits.org) messages since the last tag:

| Commit | Release |
|---|---|
| `feat: …` | minor (0.1.0 → 0.2.0) |
| `fix: …`, `perf: …` | patch (0.1.0 → 0.1.1) |
| `feat!: …` or `BREAKING CHANGE` in the body | major |
| `docs`, `chore`, `ci`, `test`, `build`, `refactor`, `style` only, or `[skip release]` | no release |

When a release is due, GitHub Actions builds the DMG, tags the version and publishes the release with generated notes. The logic lives in `AndroidMonitor/Scripts/next-version.sh` and `.github/workflows/release.yml`; pull requests only run a build check (`ci.yml`).

## How it works

- `Sources/AndroidMonitorCore`: UI-independent services (ADB process runner, device registry, files, logcat parsing, pairing, privilege detection)
- `Sources/AndroidMonitorApp`: SwiftUI / AppKit UI, mirror view, input and clipboard bridges
- `Scripts/cliphelper`: two tiny Java helpers (`ClipHelper`, `AppsHelper`) compiled to `Resources/amclip.jar` and run on the phone through `app_process` for the clipboard and app icons; rebuild with `Scripts/build-cliphelper.sh` (needs a JDK and the Android SDK, `platforms/android-33` and `d8`)
- `Scripts/make-icon.swift`: generates the app icon

Mirroring uses `adb exec-out screenrecord`, so latency depends on the phone's encoder. A scrcpy-style server would lower it; that is a possible future step.

## Safety

- Root and protected-file writes run only after an explicit confirmation showing device, path and access level
- Pairing codes, clipboard contents and file contents are not written to logs
- Helpers run through `adb shell`; nothing persistent is installed on the phone

## Limitations

- iOS: no touch or keyboard control, no file access, no logs yet; screen needs a USB cable
- Typing in the mirror sends ASCII keystrokes; use ⌘V to enter other scripts
- The clipboard bridge handles text only (no images or files)
- One active device at a time; Apple Silicon only for now

## License

MIT, see [LICENSE](LICENSE). Third-party notices, including the Apache 2.0 text for `adb`, are in [NOTICE](NOTICE). `adb` is Google's tool; it is downloaded at build time, not stored in this repository, and bundled unmodified in release builds.
