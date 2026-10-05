# Glucose App

A personal, **local-only** iPhone app for the FreeStyle Libre 2 and Libre 2 Plus (EU) sensors. It reads glucose directly over Bluetooth and shows live values, trends, fully customizable alerts and statistics. Nothing is sent to any cloud.

> **Not a medical device.** This is a personal project without regulatory clearance. Use it as a secondary display. Always confirm with an approved device before any treatment decision, and keep a backup (reader or fingerstick meter). Don't distribute builds to other people.

![Core tests](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/core-tests.yml/badge.svg)
![iOS build](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/ios-build.yml/badge.svg)

## Features

| Area | What it does |
|---|---|
| Sensor link | NFC pairing (takes over a sensor started with LibreLink), Bluetooth stream every minute, automatic reconnect and background restoration, NFC scan to fill gaps (8 h history) |
| Values | Fingerstick calibration of the raw signal (Abbott's algorithm isn't public), accuracy tracking (MARD, 15/15 band), mg/dL and mmol/L |
| Alerts | Up to 5 low + 5 high rules: silent / tune / voice, Critical Alert option, repeat, snooze, schedule, confirmation delay, re-arm margin. Only the most severe crossed rule sounds |
| Trend alerts | "Low soon" (20-minute projection), falling fast, rising fast |
| Other alerts | Missing data (scheduled ahead, fires even if the app is killed), sensor ending, Bluetooth off, low phone battery, app build expiring |
| Sounds | Separate low and high alarms, chime, pulse, 9 voice clips, import your own tunes |
| Reports | 1-90 days: time in ranges with consensus targets, mean, GMI, SD, CV, day/night, AGP, daily overlay, PDF and CSV export |
| Logbook | Meals, insulin, exercise and notes, shown as chart markers |
| Privacy | All data on the phone, excluded from iCloud backup, optional Face ID lock, password-encrypted backup file |
| Surfaces | Home-screen and lock-screen widgets, Live Activity with Dynamic Island |
| Demo | A simulated sensor (real time or 60x) to try everything without a sensor |

## Repository layout

```
Packages/GlucoseCore/        Pure Swift, tested on Linux in CI
  Sources/GlucoseCore/       Units, readings, trend, alert engine, statistics, calibration, storage, exports
  Sources/LibreProtocol/     Libre 2 crypto, FRAM and BLE parsing, sensor record
App/
  project.yml                XcodeGen spec (Xcode project, Info.plists and entitlements are generated)
  GlucoseApp/                SwiftUI app: Model, Sensor (NFC, BLE), Services, Views, Resources/Sounds
  GlucoseWidget/             Widgets and Live Activity
  Shared/                    Code compiled into both
tools/generate-sounds.ps1    Regenerates the alert sounds on Windows
.github/workflows/           Linux tests; IPA build and simulator screenshots on macOS
```

## Developing without a Mac

Everything compiles in the cloud on GitHub Actions:

1. Push to `main`.
2. **Core tests** run `swift test` on Linux.
3. **iOS build** produces `GlucoseApp.ipa` (Actions → latest run → Artifacts) and a **screenshots** artifact with every screen, captured in the iOS Simulator.

### Installing with TestFlight

For family or anyone not near your computer, see [TESTFLIGHT.md](TESTFLIGHT.md). It needs the paid Apple Developer Program, and each build lasts 90 days.

### Installing on your iPhone from Windows

1. Install [Sideloadly](https://sideloadly.io/). It needs the non-Microsoft-Store versions of iTunes and iCloud.
2. Download the `GlucoseApp-ipa` artifact from the latest **iOS build** run and unzip it.
3. Connect the iPhone by USB, drop the `.ipa` into Sideloadly and sign with your Apple ID.
4. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID, and enable Developer Mode.

**Free Apple ID:** the app expires after **7 days** and must be re-signed (the app warns you 24 h and 2 h before). NFC pairing isn't available to free accounts, so only the demo sensor works. If Sideloadly complains about entitlements, use its option to remove them.

**Paid Apple Developer Program:** 1-year signing, NFC, and the ability to request Critical Alerts. Needed before relying on the app.

## Using a real sensor

1. Start the sensor with LibreLink or the Abbott reader and let it warm up (60 min).
2. In the app: Home → sensor icon → **Pair sensor (NFC)**. LibreLink's alarms stop for that sensor from now on.
3. Add a **fingerstick** when glucose is steady, and at least once a day. Until then values are rough estimates (raw ÷ 8.5).
4. Add some fingersticks *without* "Use to calibrate" to measure accuracy (MARD).

The protocol follows community reverse-engineering and is verified here only with synthetic data. If pairing or decoding fails, use **Sensor → Share raw sensor captures** and keep the file private: it contains your sensor's ID.

## Alert behaviour

- When several rules are crossed at once, only the **most severe** sounds; the rest are marked as handled.
- A rule fires once per crossing, repeats until acknowledged (or up to its max), and re-arms after recovery plus margin.
- The app warns before you remove or turn off your last alert at or below 60 mg/dL.
- Every decision is written to a decision log (Settings → Diagnostics).

## References

Protocol work is guided by the open-source projects [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift), [DiaBLE](https://github.com/gui-dos/DiaBLE) and [LibreTransmitter](https://github.com/LoopKit/LibreTransmitter). Check their licences before reusing any code.
