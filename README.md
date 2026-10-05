# Glucose App

A personal, **local-only** iPhone app for the FreeStyle Libre 2 Plus (EU) sensor. It reads glucose directly over Bluetooth and shows live values, trends, fully customizable alerts and statistics. Nothing is sent to Abbott or any cloud.

> **Not a medical device.** This is a personal project without regulatory clearance. Use it as a secondary display. Always confirm with an approved device before any treatment decision, and keep a backup (reader or fingerstick meter). Don't distribute builds to other people.

![Core tests](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/core-tests.yml/badge.svg)
![iOS build](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/ios-build.yml/badge.svg)

## Status

| Phase | Scope | State |
|---|---|---|
| Core logic | Units, reading pipeline (dedupe/backfill), trend arrows, alert rule engine (5 low + 5 high), missing-data alert, statistics (TIR, GMI, CV), AGP | ✅ with unit tests |
| App skeleton | Home with chart, reports, alert rule editor, settings, notifications; driven by a **simulated sensor** | ✅ |
| 1. Sensor link | NFC activation + Bluetooth streaming for Libre 2 Plus EU | ⏳ next |
| 2. Persistence | Encrypted on-device reading store, export/import | ⏳ |
| 3+ | Bundled tunes/voice clips, Critical Alerts, PDF/CSV export, widgets, Live Activity, Watch | ⏳ |

## Repository layout

```
Packages/GlucoseCore/   Pure Swift logic, no iOS frameworks; tested on Linux in CI
  Sources/GlucoseCore/
    GlucoseUnit, GlucoseReading, Trend
    Alerts/      AlertRule, AlertRuleSet, AlertEngine, MissingDataAlert
    Analytics/   GlucoseStatistics, AmbulatoryGlucoseProfile
    Simulation/  SimulatedSensor
App/
  project.yml   XcodeGen spec (the .xcodeproj is generated, not committed)
  GlucoseApp/   SwiftUI app
.github/workflows/
  core-tests.yml  swift test on Linux, every push
  ios-build.yml   builds an unsigned .ipa on a macOS runner
```

## Developing without a Mac

Everything builds in the cloud on GitHub Actions:

1. Push to `main`.
2. **Core tests** run `swift test` on Linux.
3. **iOS build** compiles the app on a macOS runner and uploads `GlucoseApp-unsigned.ipa` as a build artifact (Actions tab → latest run → Artifacts).

### Installing on your iPhone from Windows

1. Install [Sideloadly](https://sideloadly.io/) on Windows. It needs the non-Microsoft-Store versions of iTunes and iCloud.
2. Download the `.ipa` artifact from the latest **iOS build** run and unzip it.
3. Connect the iPhone by USB, drop the `.ipa` into Sideloadly and sign with your Apple ID.
4. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID. On iOS 16+ also enable Developer Mode.

With a **free Apple ID** the app expires after **7 days** and must be re-signed. For a glucose app that's a real risk: an expired app silently stops alerting. Before relying on alerts, get the paid Apple Developer Program (1-year signing, NFC, and the ability to request Critical Alerts).

### Running tests locally (optional)

Tests run in CI, so a local toolchain isn't needed. On a Mac, or any machine with Swift installed:

```bash
swift test --package-path Packages/GlucoseCore
```

## Alert behaviour

- Up to **5 low and 5 high** rules, each with its own threshold, sound (silent / tune / voice), Critical Alert option, repeat, snooze, schedule, confirmation delay and re-arm margin.
- When several rules are crossed at once, only the **most severe** sounds; the rest are marked as handled.
- A rule fires once per crossing, repeats until acknowledged (or up to its max), and re-arms only after the value recovers past threshold + margin.
- **Missing-data alerts** are scheduled ahead of time as local notifications and rescheduled on every reading, so they still fire if iOS kills the app.
- Every decision is written to a decision log (Settings → Diagnostics).

## References

Protocol work is guided by the open-source projects [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift), [DiaBLE](https://github.com/gui-dos/DiaBLE) and [LibreTransmitter](https://github.com/LoopKit/LibreTransmitter). Check their licences before reusing any code.
