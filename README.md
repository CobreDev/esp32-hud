# ESP32 HUD

A desk HUD for macOS: a 1.28" round GC9A01 (240×240) on an ESP32-S3-Zero, fed over USB.

* **`MacHUD/`**: menu bar app. Renders every frame, previews it in the popover, sends it as JPEG.
* **`firmware/`**: Arduino sketch. Receives JPEG, decodes, draws. Design changes never need a reflash.
* **`PROTOCOL.md`**: the serial protocol.

## 1. Flash the firmware

Requirements: esp32 core 3.3.x and the LovyanGFX library (Library Manager → "LovyanGFX").

**Arduino IDE:** open `firmware/firmware.ino`, then pick the board *ESP32S3 Dev Module* with
*USB CDC On Boot: Enabled*, *PSRAM: QSPI PSRAM*, *Flash Size: 4MB*, and upload.

**arduino-cli:**

```bash
arduino-cli compile --fqbn esp32:esp32:esp32s3:CDCOnBoot=cdc,PSRAM=enabled,FlashSize=4M firmware
```

```bash
arduino-cli upload --fqbn esp32:esp32:esp32s3:CDCOnBoot=cdc,PSRAM=enabled,FlashSize=4M -p /dev/cu.usbmodem1101 firmware
```

(`arduino-cli board list` shows the actual port.)

If MacHUD is running, click **Release Port** in its popover first, and **Reconnect** afterwards.
If an upload won't start, hold BOOT while plugging the board in.

After boot the display shows **"Waiting for Mac..."** until the app connects.

## 2. Build and run the Mac app

Requires macOS 14+ and Xcode.

```bash
open MacHUD/MacHUD.xcodeproj
```

Then press Run. Or from the command line:

```bash
xcodebuild -project MacHUD/MacHUD.xcodeproj -scheme MacHUD -configuration Release build
```

The app lives in the menu bar only (no Dock icon). Click the circle icon for the popover:
live preview, HUD on/off, connection status, Launch at Login, Release Port, and Quit.

The project is generated from `MacHUD/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing source files, run `xcodegen` in `MacHUD/` (or just edit the project in Xcode).

**Signing:** the project signs ad-hoc ("Sign to Run Locally"). That works, but macOS ties the
Automation permission to the code signature. Ad-hoc builds can therefore ask again after a rebuild.
For a stable setup, select your Apple Development team under *Signing & Capabilities*.
Launch at Login works best with the app copied to `/Applications`.

## 3. Grant the Music automation permission

The first time Music is playing while MacHUD runs, macOS asks:
*"MacHUD" wants access to control "Music".* Click **Allow**.

If you clicked *Don't Allow*, or the prompt never appeared:

1. Open **System Settings → Privacy & Security → Automation** (the popover has an *Open Settings* button).
2. Under **MacHUD**, turn on **Music**.
3. Click **Retry** in the popover.

To get the prompt again from scratch:

```bash
tccutil reset AppleEvents local.machud.MacHUD
```

MacHUD never launches Music itself. While Music isn't running (or nothing is playing), the HUD shows a clock.

## Screens

The popover's **Screen** menu is **Automatic** by default, or pins one screen.

| Screen | Automatic behaviour |
|---|---|
| **Music** | Shown while Apple Music is playing, and for 5 minutes after it pauses. |
| **Notification** | Shown for 8 s when a banner appears, over everything else. Needs the Accessibility permission (see below). |
| **Dashboard** | Time, date, battery and outside temperature. Shown when nothing else applies. |
| **Weather** | Pin-only: choose it in the Screen menu. (Open-Meteo, using macOS Location.) |

### Notifications

macOS has no public API for other apps' notifications, so MacHUD watches Notification Center's banners
through **Accessibility**. Turn on MacHUD under System Settings → Privacy & Security → Accessibility
(the popover's Notifications row has a button). The sending app's icon is taken from its `.app` file.

This is best-effort: it depends on how macOS builds banners, and Do Not Disturb / Focus hides banners.
To record what a banner looks like to MacHUD, for troubleshooting:

```bash
defaults write local.machud.MacHUD notificationDebug -bool YES
```

The dump goes to `~/Library/Application Support/MacHUD/notification-debug.txt` (it includes the banner text).
Turn it off with `defaults delete local.machud.MacHUD notificationDebug`.

## Architecture

| Module | File | Role |
|---|---|---|
| `NowPlayingSource` | `NowPlaying/NowPlayingSource.swift` | Protocol for now-playing providers (add Spotify / system stats here) |
| `AppleMusicSource` | `NowPlaying/AppleMusicSource.swift` | `com.apple.Music.playerInfo` notifications + AppleScript for details and artwork |
| `HUDRenderer` | `Rendering/HUDRenderer.swift` | Core Graphics drawing of a `HUDScene` → 240×240 image → JPEG (q 0.8, baseline) |
| `SerialLink` | `Serial/SerialLink.swift` | POSIX termios + IOKit discovery, HELLO handshake, ACK flow control, resync, reconnect |
| `AppState` | `App/AppState.swift` | Glue + animation: cross-fades on content changes, eases the progress ring on seeks/track changes. Renders at 15 Hz while playing or animating, 1 Hz otherwise, and only when the frame would actually change |

## Notes

* Animations run as fast as the display can take frames (about 10 fps). The display draws a
  frame in ~66 ms, and the serial link always sends the newest frame and drops stale ones.
* The module has no backlight pin, so **HUD disabled** blacks out the panel and puts the GC9A01
  into sleep. The backlight itself stays on.
* The app doesn't take exclusive access to the port, but anything else reading it at the same time
  will garble the stream. Use **Release Port** for uploads or a serial monitor.
