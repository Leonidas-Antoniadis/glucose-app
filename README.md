# Glucose App

A personal, **local-only** iPhone app for the FreeStyle Libre 2 and Libre 2 Plus (EU) sensors. It reads glucose directly over Bluetooth and shows live values, trends, fully customizable alerts and statistics. Nothing is sent to any cloud.

> **Not a medical device.** This is a personal project without regulatory clearance. Use it as a secondary display. Always confirm with an approved device before any treatment decision, and keep a backup (reader or fingerstick meter). Share builds only with family on your own Apple Developer team (TestFlight internal testers), not with anyone else.

![Core tests](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/core-tests.yml/badge.svg)
![iOS build](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/ios-build.yml/badge.svg)

## Screenshots

Captured automatically in the iOS Simulator by the iOS build, using the demo sensor and sample data. The latest full set is attached to each [iOS build run](https://github.com/Leonidas-Antoniadis/glucose-app/actions/workflows/ios-build.yml) as the `screenshots` artifact.

| Home | Past values | Dark mode |
|:---:|:---:|:---:|
| <img src="docs/screenshots/home.png" width="230" alt="Home screen with current value, trend arrow, quick-add buttons and chart"> | <img src="docs/screenshots/home-chart.png" width="230" alt="Chart with a past value selected, showing a fingerstick nearby"> | <img src="docs/screenshots/home-dark.png" width="230" alt="Home screen in dark mode"> |
| Current value, trend and quick logging | Swipe back through 14 days; touch and hold to read a value | |

| Log an entry | Logbook | Reports |
|:---:|:---:|:---:|
| <img src="docs/screenshots/add-entry.png" width="230" alt="Add fast-acting insulin form"> | <img src="docs/screenshots/logbook.png" width="230" alt="Logbook timeline grouped by day"> | <img src="docs/screenshots/reports.png" width="230" alt="Reports with time in ranges and glucose metrics"> |
| Fast / slow insulin, food, exercise, blood glucose | One timeline, grouped by day | Time in ranges with consensus targets |

| Alerts | Alert editor | First launch |
|:---:|:---:|:---:|
| <img src="docs/screenshots/alerts.png" width="230" alt="Low and high alert rules"> | <img src="docs/screenshots/alert-editor.png" width="230" alt="Editing an alert rule"> | <img src="docs/screenshots/onboarding.png" width="230" alt="Onboarding with the not-a-medical-device notice"> |
| 5 low + 5 high, separate low and high alarms | Sound, Sound through Silent mode and Focus, repeat, snooze, schedule | Safety notice, units, presets, data source |

| Battery and Lock Screen |
|:---:|
| <img src="docs/screenshots/battery-lock-screen.png" width="230" alt="Settings with Show Live Activity again, Run in background and 91 days of data kept"> |
| Bring back the Live Activity, save battery, 91 days kept |

| Bedtime check | Sensor wear and signal | Accuracy |
|:---:|:---:|:---:|
| <img src="docs/screenshots/bedtime.png" width="230" alt="Ready for tonight card listing passed checks and tonight's summary"> | <img src="docs/screenshots/wear.png" width="230" alt="Day 9 of 15 with a strip of the sensor's days, Bluetooth signal and gaps"> | <img src="docs/screenshots/accuracy.png" width="230" alt="MARD with its 95% range, bias, LibreLink comparison and the consensus error grid"> |
| What could keep an alarm from sounding tonight | Data captured per day, signal strength, gaps with reasons | MARD, error grid, LibreLink on the same checks |

| Sensor | Raw sensor data | Packet bytes | Sensor history |
|:---:|:---:|:---:|:---:|
| <img src="docs/screenshots/sensor.png" width="175" alt="Sensor status, pairing and calibration"> | <img src="docs/screenshots/raw-data.png" width="175" alt="List of Bluetooth packets and NFC reads"> | <img src="docs/screenshots/packet.png" width="175" alt="One packet's bytes, encrypted and decrypted, colored by meaning"> | <img src="docs/screenshots/sensor-history.png" width="175" alt="Last 5 sensors with serials and end reasons"> |
| Pairing, calibration, accuracy | Every packet and NFC read | Bytes colored by meaning | Last 5 sensors for support calls |

## Features

| Area | What it does |
|---|---|
| Sensor link | NFC pairing (takes over a sensor started with LibreLink), Bluetooth stream every minute, automatic reconnect and background restoration, NFC scan to fill gaps (8 h history) |
| Sensor wear | "Day 9 of 15" with a strip of the sensor's days (data captured, calibrations, error that day); Bluetooth strength, packets, reconnects, checksum errors and noise over 24 hours; every gap with its reason |
| Values | Fingerstick calibration of the raw signal (Abbott's algorithm isn't public), mg/dL and mmol/L |
| Accuracy | MARD with its 95% range, within 15/15 and 20/20, bias, a consensus (Parkes) error grid, where the sensor is weaker (range, sensor day, rate of change), the LibreLink value typed with a fingerstick compared on the same checks, CSV export |
| Alerts | Up to 5 low + 5 high rules at any value from 40 to 400 mg/dL: silent / tune / voice, sound through Silent mode and Focus, repeat, snooze, schedule, confirmation delay, re-arm margin. Only the most severe crossed rule sounds |
| Trend alerts | "Low soon" (20-minute projection), falling fast, rising fast |
| Lock Screen alert | Notifications like "Lower · 64 mg/dL ↘ · −9 in 15 min. Below 70 since 3:01 AM." with a 2-hour chart; during an alert the Live Activity turns red (low) or orange (high) with Snooze and Treating buttons that work without opening the app |
| Bedtime check | From an hour before bedtime, "Ready for tonight?" lists what could keep an alarm from sounding (volume, battery, Bluetooth, no-data alert, Silent mode, sensor or app build ending overnight) and how to fix it; a notification at bedtime if something needs fixing or no readings arrive |
| Other alerts | Missing data (scheduled ahead, fires even if the app is killed), sensor ending, Bluetooth off, low phone battery, app build expiring |
| Sounds | Separate low and high alarms (including ultra loud, high-pitched ones), chime, pulse, 9 voice clips, import your own tunes |
| Reports | 1-90 days: time in ranges with consensus targets, mean, GMI, SD, CV, day/night, AGP, daily overlay, PDF and CSV export |
| Logbook | Meals, insulin, exercise and notes, shown as chart markers. From the home screen: food in one tap, insulin with your usual doses, Undo, and when you last took insulin and ate |
| Privacy | All data on the phone, excluded from iCloud backup, kept for 91 days then deleted, optional Face ID lock (also covers the App Switcher), option to hide values on the Lock Screen, password-encrypted backup file |
| Battery | "Run in background" switch: off stops the sensor connection while the app is closed (no alerts then) and resumes when you open it |
| Surfaces | Home-screen and lock-screen widgets, Live Activity with Dynamic Island, button to bring the Live Activity back after swiping it away |
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
tools/testflight-upload.sh   Uploads to TestFlight from a Mac (CI does this on every push)
.github/workflows/           Linux tests; IPA build and simulator screenshots on macOS; TestFlight upload
```

## Developing without a Mac

Everything compiles in the cloud on GitHub Actions:

1. Push to `main`.
2. **Core tests** run `swift test` on Linux.
3. **iOS build** produces `GlucoseApp.ipa` (Actions → latest run → Artifacts) and a **screenshots** artifact with every screen, captured in the iOS Simulator.
4. **TestFlight upload** runs the core tests again and, if they pass, uploads the build. Every push to `main` that changes `App/` or `Packages/` reaches testers in the internal group within minutes.

### Installing with TestFlight

For family members on your Apple Developer team, see [TESTFLIGHT.md](TESTFLIGHT.md): every push to `main` uploads a new build automatically, and one script uploads from a Mac. It needs the paid Apple Developer Program, and each build lasts 90 days.

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
   - If LibreLink is on the same iPhone, turn off its Bluetooth (iPhone Settings → LibreLink → Bluetooth). Otherwise it keeps trying to connect to the sensor and breaks this app's connection ([xDrip4iOS requires the same](https://xdrip4ios.readthedocs.io/en/latest/connect/cgm/)). LibreLink can still scan by NFC.
   - Or skip LibreLink: apply a new sensor, then tap **Start a new sensor (NFC)**. The app starts it and pairs it in one scan. This is experimental (not yet tried on a real sensor), starting can't be undone, and LibreLink may not give alarms for a sensor it didn't start. If you might want to switch back to LibreLink, start the sensor there instead.
3. Add a **fingerstick** when glucose is steady, and at least once a day. Until then values are rough estimates (raw ÷ 8.5).
4. Every fingerstick also measures accuracy (MARD), including the ones used to calibrate: those are scored against the value shown before calibrating, so the misses you calibrate away still count.

The protocol follows community reverse-engineering (DiaBLE, LibreTransmitter). The tests check it against LibreTransmitter's public captures from real Libre 2 sensors and against values computed with the reference code, but it hasn't been tried on a sensor of our own yet. Before taking over a sensor, the app checks that its data decodes; if it doesn't, nothing on the sensor changes and LibreLink keeps working. Failed reads are kept under **Sensor → Raw sensor data** so they can be shared to fix decoding. Keep that file private: it contains your sensor's ID.

### Common situations

| Situation | What happens |
|---|---|
| Taking over a sensor that's already running | No new warm-up. Pairing imports the last 8 hours right away; live readings start within 1-2 minutes. Add a fingerstick soon, since values are estimates until calibrated. |
| Pairing a sensor that's still warming up | Readings start after its first 60 minutes, and a "Sensor ready" notification arrives then. |
| Alerts in both apps? | No. The sensor streams to one app. After pairing here, LibreLink's alarms stop for that sensor. |
| Going back to LibreLink | Turn LibreLink's Bluetooth back on, then scan the sensor with LibreLink; it usually takes the sensor back (not guaranteed). This app then shows "No reading since …" with a **Pair again** button. |
| Scanning again while connected | Safe: it only reads the 8-hour history, fills gaps and doesn't disturb the Bluetooth link. |
| Pairing the same sensor again | Allowed; calibration is kept. |
| Phone left out of range | It reconnects by itself when you're back (this can take a few minutes); no new pairing is needed. If a connection stays up but no data arrives for 4 minutes, the app drops and remakes it. Each Bluetooth packet only covers the last ~45 minutes, so a banner offers an NFC scan to fill longer gaps (the sensor keeps 8 hours). |
| Phone restarted | iOS only reconnects after the app has been opened once; the scheduled "No glucose data" alert reminds you. |

### Raw sensor data

**Sensor → Raw sensor data** shows each Bluetooth packet and NFC read as received, decrypted and decoded, with bytes colored by meaning. Recent packets are kept only in memory. To keep one on the phone, turn on **Save the next Bluetooth packet** (or NFC read), or swipe a packet and tap **Keep**. Kept data can be shared as a text file.

## Alert behaviour

- When several rules are crossed at once, only the **most severe** sounds; the rest are marked as handled.
- A rule fires once per crossing, repeats until acknowledged (or up to its max), and re-arms after recovery plus margin.
- The app warns before you remove or turn off your last alert at or below 60 mg/dL.
- Every decision is written to a decision log (Settings → Diagnostics).
- Every alert, including trend alerts and the missing-data alert, has a **Send test alert** button that sends it with its real sound (the app's own alarm plays for 8 seconds in a test, 30 in a real alert).

### Alerts through Silent mode and Focus (no Apple approval needed)

Turn on **Sound through Silent mode and Focus** for an alert (Alerts → tap the alert). Then:

1. **Silent switch:** the app plays the alarm itself, which iOS doesn't mute. Keep **Run in background** on (Settings → Battery) and the sensor connected. It plays at your **media volume**, so keep that turned up. It stops when you open the app, tap Snooze, or after 30 seconds.
2. **Focus:** on the iPhone, open **Settings → Notifications → Glucose** and turn on **Time Sensitive Notifications**. The "Open Settings" button on the home screen's Critical alerts card goes straight there.
   - If a Focus still hides the alerts, open **Settings → Focus → (each Focus) → Apps** and add **Glucose**.

The home screen's **Critical alerts** card shows a check for each step. Once Apple grants the app the Critical Alerts entitlement, alerts become true Critical Alerts: they sound at full volume through everything, even when the app isn't running.

## References

Protocol work is guided by the open-source projects [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift), [DiaBLE](https://github.com/gui-dos/DiaBLE) and [LibreTransmitter](https://github.com/LoopKit/LibreTransmitter). Check their licences before reusing any code.
