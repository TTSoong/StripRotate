# Strip Rotate

A free, open-source macOS menu bar utility for portrait and ultra-tall displays whose USB graphics driver does not expose native rotation.

Strip Rotate detects portrait external displays, creates a virtual display with the width and height swapped, captures it, rotates the image by 90°, and presents it full-screen on the physical display.

For example: `450×1920` physical display → `1920×450` virtual desktop.

> Requires macOS 14 or later. The downloadable build is ad-hoc signed and not notarized.

## Download and install

1. Download the latest `Strip-Rotate-macOS.zip` from [Releases](https://github.com/TTSoong/StripRotate/releases/latest).
2. Unzip it and move `Strip Rotate.app` to **Applications**.
3. Right-click the app and choose **Open** the first time.
4. Allow **Screen & System Audio Recording**, quit the app completely, then reopen it.
5. In **System Settings → Displays → Arrange**, place the `Strip Rotate WIDTHxHEIGHT` virtual display beside your main display. Move the physical portrait output away from the edge you normally cross.
6. Drag windows onto the virtual display. The rotated output appears on the physical portrait display.

If multiple portrait external displays are connected, choose the target from the menu bar under **Output Display / 輸出螢幕**.

## Features

- Automatically detects external displays whose pixel height is greater than their width.
- Waits silently when the selected display is disconnected and reconnects only after a macOS display-change event; no disconnected-state polling or repeated alerts.
- Creates a matching virtual desktop with width and height swapped.
- Supports clockwise and counterclockwise rotation.
- Remembers the selected target and display arrangement.
- Optional launch at login.
- Shows the installed app version and build number directly in the menu.
- Recovers after sleep, display reconfiguration, and interrupted capture.
- Suspends the physical output overlay while the macOS session is locked, then safely restores it after unlock.
- Retries virtual-display creation with fallback identities when WindowServer is still recovering after login or unlock.
- Rebuilds the capture pipeline after every lock/sleep cycle and verifies that the restarted stream actually produces a frame.
- Defers saved-layout restoration until displays have settled and skips the WindowServer configuration transaction when the arrangement is already correct.
- Cursor guard prevents the pointer from entering the physical output desktop.

## Privacy permission reset

If macOS repeatedly asks for screen-recording permission, quit the app, make sure it is in `/Applications`, then run:

```bash
tccutil reset ScreenCapture tw.kayinsoong.StripRotate
```

Open the app, grant permission once, quit it completely, and reopen it.

## Limitations

- Uses the private macOS `CGVirtualDisplay` API, which may change in a future macOS release.
- The physical display remains present in macOS display arrangement because it is the output device.
- Protected DRM video may not be capturable.
- The release is not Apple-notarized. Review the source and build it locally if preferred.

## Build from source

Install Xcode Command Line Tools, then run:

```bash
./build-app.sh
```

The app archive is written to `dist/Strip-Rotate-macOS.zip`.

## 中文說明

Strip Rotate 是免費、開源的 macOS 選單列工具，適合 USB 顯示卡驅動沒有提供旋轉功能的直向或長條螢幕。

它會自動偵測「高度大於寬度」的外接螢幕，建立寬高互換的虛擬桌面，再將畫面旋轉 90° 輸出到實體螢幕。例如實體螢幕是 `450×1920`，就會建立 `1920×450` 虛擬桌面。

使用者只需把 App 放入「應用程式」、允許「螢幕與系統錄音」，再於「顯示器排列」中把 Strip Rotate 虛擬螢幕放在主螢幕旁。若連接多台直向螢幕，可從選單列選擇輸出目標。

## License

Strip Rotate is released under the MIT License. Private CoreGraphics declarations were adapted from DeskPad by Bastian Andelefski under the MIT License; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
