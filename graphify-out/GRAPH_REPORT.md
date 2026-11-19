# Graph Report - glucose-app  (2026-10-05)

## Corpus Check
- 73 files · ~236,542 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1379 nodes · 3400 edges · 81 communities (77 shown, 4 thin omitted)
- Extraction: 89% EXTRACTED · 11% INFERRED · 0% AMBIGUOUS · INFERRED: 375 edges (avg confidence: 0.81)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `42546a6a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- FingerstickEntry
- .reading
- MissingDataAlert
- GlucoseReading
- Foundation
- LibreBLE
- AlertRuleSet
- BackupPayload
- RuleEditorView
- String
- View
- AppModel
- LibreNFCReader
- ReadingArchive
- AlertEngine
- SensorConnection
- .pdf
- Sendable
- DemoSpeed
- Libre2Crypto
- ReportsView.swift
- AlertRule
- LibreSensorType
- .activateSource
- GlucoseWidget.swift
- TrendAlert
- CodingKeys
- GlucoseUnit
- .crc16
- SurfaceUpdater
- Status
- Glucose App README
- Installing Glucose with TestFlight
- iOS build workflow
- GlucoseEntry
- LibreProtocolTests
- LogEntry
- Hashable
- .blePacket
- TrendAlertTests
- Ship and check skill
- Components.swift
- LibreProtocolError
- Identifiable
- NotificationService
- InsulinType
- QuickLogKind
- .scenePhaseChanged
- LibreSensorRecord
- XcodeGen spec (project.yml)
- XCTestCase
- Event
- Paid Developer Program required for NFC
- Glucose App Icon
- SoundStyle
- bluetooth-central background mode
- PackageDescription
- AppStores
- QuickDoseSheet
- GlucoseCore
- GlucoseChart
- RuleSetAndScheduleTests
- .body
- HomeQuickLog
- HomeView.swift
- Row
- SystemServices.swift
- .color
- AmbulatoryGlucoseProfile
- TrendArrow
- QuickLogTests
- OnboardingView
- ScreenshotMode
- .userNotificationCenter
- GlucoseWidgetView
- SurfaceUpdater.swift
- CurrentValueCard
- SwiftUI
- Kind
- testflight-upload.sh

## God Nodes (most connected - your core abstractions)
1. `AppModel` - 77 edges
2. `SensorConnection` - 65 edges
3. `GlucoseReading` - 51 edges
4. `LogEntry` - 47 edges
5. `AlertRule` - 45 edges
6. `GlucoseCore` - 35 edges
7. `AlertRuleSet` - 35 edges
8. `LibreSensorRecord` - 33 edges
9. `Glucose App README` - 33 edges
10. `GlucoseUnit` - 32 edges

## Surprising Connections (you probably didn't know these)
- `NFC 8-hour history gap fill` --implements--> `LibreNFCReader`  [INFERRED]
  README.md → App/GlucoseApp/Sensor/LibreNFCReader.swift
- `Screenshot launch arguments (-screenshots, -onboarding, -tab N)` --references--> `ScreenshotMode`  [INFERRED]
  .github/workflows/ios-build.yml → App/GlucoseApp/App/GlucoseApp.swift
- `MainActor.assumeIsolated in delegate callbacks` --conceptually_related_to--> `LibreBLE`  [INFERRED]
  .claude/skills/ship-and-check/SKILL.md → App/GlucoseApp/Sensor/LibreBLE.swift
- `Bluetooth one-minute stream with reconnect/restoration` --implements--> `LibreBLE`  [INFERRED]
  README.md → App/GlucoseApp/Sensor/LibreBLE.swift
- `MainActor.assumeIsolated in delegate callbacks` --conceptually_related_to--> `LibreNFCReader`  [INFERRED]
  .claude/skills/ship-and-check/SKILL.md → App/GlucoseApp/Sensor/LibreNFCReader.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Alert behaviour model** — readme_alert_rules, readme_most_severe_only, readme_rearm_margin, readme_decision_log, readme_trend_alerts, readme_missing_data_alert, packages_glucosecore_sources_glucosecore_alerts_alertengine_alertengine [INFERRED 0.85]
- **App distribution paths and their expiry limits** — _claude_skills_install_on_iphone_skill_sideloadly, _claude_skills_install_on_iphone_skill_free_apple_id_7_day_expiry, testflight_testflight_distribution, testflight_90_day_build_expiry, readme_build_expiry_alert [INFERRED 0.85]
- **Windows-only CI build-and-sideload pipeline** — _claude_skills_ship_and_check_skill_github_actions_as_compiler, _github_workflows_ios_build_xcodegen_generate, _github_workflows_ios_build_build, _github_workflows_ios_build_adhoc_sign_with_entitlements, _claude_skills_install_on_iphone_skill_glucoseapp_ipa_artifact, _claude_skills_install_on_iphone_skill_sideloadly [INFERRED 0.85]

## Communities (81 total, 4 thin omitted)

### Community 0 - "FingerstickEntry"
Cohesion: 0.12
Nodes (22): .accuracy, AccuracyReport, .mard, .within15_15, Calibration, .isCalibrated, CalibrationPoint, FingerstickEntry (+14 more)

### Community 1 - ".reading"
Cohesion: 0.10
Nodes (19): GlucoseStatistics, .hasSufficientData, .isCVStable, RangeBreakdown, .aboveRange, .belowRange, .meetsConsensusTargets, Bool (+11 more)

### Community 2 - "MissingDataAlert"
Cohesion: 0.08
Nodes (21): MissingDataAlert, .minutes, SensorLifecycle, Bool, Calendar, ClosedRange, Date, Int (+13 more)

### Community 3 - "GlucoseReading"
Cohesion: 0.07
Nodes (29): .chartReadings, .readingGap, .trendArrow, GlucoseReading, .id, ReadingPipeline, Source, backfill (+21 more)

### Community 4 - "Foundation"
Cohesion: 0.17
Nodes (7): CommonCrypto, CoreNFC, CryptoKit, Foundation, LibreProtocol, Observation, Security

### Community 5 - "LibreBLE"
Cohesion: 0.08
Nodes (26): Any, Event, connected, connecting, disconnected, log, packet, poweredOff (+18 more)

### Community 6 - "AlertRuleSet"
Cohesion: 0.14
Nodes (15): Encoder, AlertRuleSet, .urgentLowRules, Issue, duplicateThreshold, lowAboveHigh, noEnabledRules, noUrgentLow (+7 more)

### Community 7 - "BackupPayload"
Cohesion: 0.18
Nodes (13): BackupError, .errorDescription, keyDerivationFailed, notABackup, wrongPassword, BackupPayload, BackupService, Date (+5 more)

### Community 8 - "RuleEditorView"
Cohesion: 0.08
Nodes (32): Void, AlertsView, .body, Kind, .id, silent, tune, voice (+24 more)

### Community 9 - "String"
Cohesion: 0.06
Nodes (33): SensorHistoryDetailView, .body, .normalized, .body, Bool, String, ISO8601DateFormatter, CSVExport (+25 more)

### Community 10 - "View"
Cohesion: 0.11
Nodes (34): LockView, MainTabs, .body, RootView, .body, ScreenshotScreen, .body, MetricRow (+26 more)

### Community 11 - "AppModel"
Cohesion: 0.16
Nodes (13): AppModel, .decisionLog, .isDemo, .isStale, .latest, .unit, Bool, Date (+5 more)

### Community 12 - "LibreNFCReader"
Cohesion: 0.09
Nodes (30): LibreNFCReader, Mode, pair, read, start, NFCReadError, alreadyStarted, cancelled (+22 more)

### Community 13 - "ReadingArchive"
Cohesion: 0.19
Nodes (6): JSONFileStore, ReadingArchive, Date, DateFormatter, URL, Value

### Community 14 - "AlertEngine"
Cohesion: 0.16
Nodes (19): AlertEngine, .activeRuleIDs, AlertEvent, Kind, afterSnooze, initial, reminder, Bool (+11 more)

### Community 15 - "SensorConnection"
Cohesion: 0.16
Nodes (11): NFCRecord, PacketRecord, SensorConnection, DateFormatter, Error, MainActor, Set, String (+3 more)

### Community 16 - ".pdf"
Cohesion: 0.24
Nodes (8): ReportDocument, .body, ReportExporter, Date, DateInterval, String, URL, Reports (TIR, GMI, SD, CV, AGP, PDF/CSV export)

### Community 17 - "Sendable"
Cohesion: 0.14
Nodes (18): LibreBLEPacket, .latest, LibreFRAM, LibreRawReading, State, active, .description, expired (+10 more)

### Community 18 - "DemoSpeed"
Cohesion: 0.17
Nodes (11): DataSource, demo, .id, libre, .title, DemoSpeed, fast, .id (+3 more)

### Community 19 - "Libre2Crypto"
Cohesion: 0.36
Nodes (4): Libre2Crypto, UInt16, UInt32, UInt8

### Community 20 - "ReportsView.swift"
Cohesion: 0.17
Nodes (14): DailyOverlayChart, .body, RangeRow, .body, ReportsView, .currentPeriod, Color, DateInterval (+6 more)

### Community 21 - "AlertRule"
Cohesion: 0.22
Nodes (11): RuleState, AlertDirection, high, low, AlertRule, AlertSchedule, Bool, Double (+3 more)

### Community 22 - "LibreSensorType"
Cohesion: 0.11
Nodes (17): .sensorType, LibreSensorType, .displayName, .isSupported, libre1, libre2CA, libre2EU, libre2Gen2 (+9 more)

### Community 23 - ".activateSource"
Cohesion: 0.23
Nodes (3): String, URL, .body

### Community 24 - "GlucoseWidget.swift"
Cohesion: 0.43
Nodes (7): GlucoseLiveActivity, GlucoseWidget, GlucoseWidgetBundle, .body, Widget, WidgetBundle, WidgetConfiguration

### Community 25 - "TrendAlert"
Cohesion: 0.18
Nodes (13): Decoder, Kind, .direction, fallingFast, predictiveLow, risingFast, Bool, Double (+5 more)

### Community 26 - "CodingKeys"
Cohesion: 0.10
Nodes (19): CodingKeys, allowUnverifiedSensorTypes, batteryAlert, biometricLock, bluetoothAlert, dataSource, demoSpeed, liveActivity (+11 more)

### Community 27 - "GlucoseUnit"
Cohesion: 0.17
Nodes (11): VoiceAnnouncer, .body, AGPChart, .body, GlucoseUnit, .editorStepMgdL, mgdL, mmolL (+3 more)

### Community 28 - ".crc16"
Cohesion: 0.31
Nodes (6): C, LibreBits, LibreCRC, Bool, UInt16, UInt8

### Community 29 - "SurfaceUpdater"
Cohesion: 0.31
Nodes (7): Activity, ActivityAttributes, SurfaceUpdater, .liveActivitiesAllowed, Bool, Int, GlucoseActivityAttributes

### Community 30 - "Status"
Cohesion: 0.14
Nodes (14): RawSample, Status, bluetoothOff, connected, connecting, ended, error, notPaired (+6 more)

### Community 31 - "Glucose App README"
Cohesion: 0.24
Nodes (12): Glucose App README, Community reverse-engineered Libre protocol, Alert decision log, DiaBLE, FreeStyle Libre 2 / Libre 2 Plus (EU) sensor, Warn before removing last alert at or below 60 mg/dL, LibreProtocol module (crypto, FRAM, BLE parsing), LibreTransmitter (+4 more)

### Community 32 - "Installing Glucose with TestFlight"
Cohesion: 0.17
Nodes (15): Free Apple ID 7-day signing expiry, XcodeGen project generation, CURRENT_PROJECT_VERSION build number, ITSAppUsesNonExemptEncryption = false, App build expiring alert, Not a medical device disclaimer, Share raw sensor captures, Installing Glucose with TestFlight (+7 more)

### Community 33 - "iOS build workflow"
Cohesion: 0.29
Nodes (10): Install on iPhone skill, Trust Apple ID and enable Developer Mode, GlucoseApp-ipa artifact, screenshots artifact, Sideloadly sideloading, iOS build workflow, Ad-hoc sign with entitlements, Build IPA job (+2 more)

### Community 34 - "GlucoseEntry"
Cohesion: 0.19
Nodes (11): GlucoseEntry, .isStale, GlucoseProvider, .body, Bool, Date, Void, Context (+3 more)

### Community 35 - "LibreProtocolTests"
Cohesion: 0.14
Nodes (6): invalidLength, Int, LibreFixtures, Int, UInt8, LibreProtocolTests

### Community 36 - "LogEntry"
Cohesion: 0.24
Nodes (10): .saveTitle, LogEntry, .csvAmount, .csvKind, .symbolName, .title, QuickLog, Date (+2 more)

### Community 37 - "Hashable"
Cohesion: 0.29
Nodes (11): ContentState, .formattedValue, Point, Date, Double, String, WidgetSnapshot, .formattedValue (+3 more)

### Community 38 - ".blePacket"
Cohesion: 0.28
Nodes (8): .body, LibreLayout, LibreSimulator, Region, Int, Range, String, UInt8

### Community 39 - "TrendAlertTests"
Cohesion: 0.36
Nodes (3): Double, String, TrendAlertTests

### Community 40 - "Ship and check skill"
Cohesion: 0.23
Nodes (12): Ship and check skill, Separate fix-forward commits, GitHub Actions as the only compiler, GlucoseCore Linux portability constraint, MainActor.assumeIsolated in delegate callbacks, Never commit .xcodeproj, SSH-signed commits, Core tests workflow (+4 more)

### Community 41 - "Components.swift"
Cohesion: 0.18
Nodes (12): Banner, .body, GlucoseValuePicker, .options, RangeColor, SelectionCallout, .body, ClosedRange (+4 more)

### Community 42 - "LibreProtocolError"
Cohesion: 0.18
Nodes (10): CustomStringConvertible, Error, LibreProtocolError, .description, invalidCRC, invalidPatchInfo, invalidUID, unsupportedSensor (+2 more)

### Community 43 - "Identifiable"
Cohesion: 0.10
Nodes (19): SavedCapture, .title, Bool, Date, UInt8, URL, HexGrid, .body (+11 more)

### Community 44 - "NotificationService"
Cohesion: 0.14
Nodes (12): NotificationService, Status, Bool, Date, MainActor, String, UUID, Double (+4 more)

### Community 45 - "InsulinType"
Cohesion: 0.17
Nodes (12): InsulinType, .displayName, .id, long, other, rapid, Kind, exercise (+4 more)

### Community 46 - "QuickLogKind"
Cohesion: 0.09
Nodes (25): AddFingerstickView, .body, AddLogEntryView, .amount, .body, .isValid, QuickAddBar, .body (+17 more)

### Community 47 - ".scenePhaseChanged"
Cohesion: 0.16
Nodes (7): App, GlucoseApp, .body, .body, Task, Scene, ScenePhase

### Community 48 - "LibreSensorRecord"
Cohesion: 0.18
Nodes (10): Int, LibreSensorRecord, .expiresAt, .warmUpEndsAt, Date, Double, Int, String (+2 more)

### Community 49 - "XcodeGen spec (project.yml)"
Cohesion: 0.36
Nodes (9): XcodeGen spec (project.yml), App group group.com.leonidasantoniadis.glucoseapp, Face ID usage description, GlucoseApp application target, GlucoseWidget app-extension target, NSSupportsLiveActivities, Time-sensitive notifications entitlement, Local-only, no cloud data (+1 more)

### Community 50 - "XCTestCase"
Cohesion: 0.29
Nodes (3): LibreSimulatorTests, Int, XCTestCase

### Community 51 - "Event"
Cohesion: 0.40
Nodes (5): Event, bluetoothOff, error, paired, sensorEnded

### Community 52 - "Paid Developer Program required for NFC"
Cohesion: 0.50
Nodes (4): Paid Developer Program required for NFC, NFC readersession TAG entitlement, Demo simulated sensor (real time or 60x), NFC pairing (sensor takeover from LibreLink)

### Community 53 - "Glucose App Icon"
Cohesion: 0.67
Nodes (4): Glucose App Icon, Blood Drop Motif, Teal-to-Blue Gradient Palette, Glucose Trend Curve with Current Reading Dot

### Community 54 - "SoundStyle"
Cohesion: 0.11
Nodes (23): AlarmPlayer, .isPlaying, ImportError, .errorDescription, tooLong, Option, SoundCatalog, .soundsDirectory (+15 more)

### Community 55 - "bluetooth-central background mode"
Cohesion: 0.67
Nodes (3): bluetooth-central background mode, Bluetooth one-minute stream with reconnect/restoration, Keep app running in background

### Community 58 - "AppStores"
Cohesion: 0.15
Nodes (9): Set, UUID, AppSettings, Decoder, AppStores, Date, String, URL (+1 more)

### Community 59 - "QuickDoseSheet"
Cohesion: 0.20
Nodes (12): LastLoggedTiles, .body, QuickDoseSheet, .amount, .body, .kind, Bool, Date (+4 more)

### Community 60 - "GlucoseCore"
Cohesion: 0.23
Nodes (3): GlucoseCore, UserNotifications, XCTest

### Community 61 - "GlucoseChart"
Cohesion: 0.28
Nodes (8): GlucoseChart, .axisStrideHours, .body, .visibleSeconds, Bool, Date, Int, TimeInterval

### Community 62 - "RuleSetAndScheduleTests"
Cohesion: 0.19
Nodes (3): Calendar, Date, RuleSetAndScheduleTests

### Community 63 - ".body"
Cohesion: 0.21
Nodes (10): Action, CriticalAlertsCard, .body, CriticalAlertsChecklist, .body, openNotificationSettings(), Bool, String (+2 more)

### Community 64 - "HomeQuickLog"
Cohesion: 0.29
Nodes (8): HomeQuickLog, .body, LoggedToast, Set, UUID, UndoToast, .body, Equatable

### Community 65 - "HomeView.swift"
Cohesion: 0.24
Nodes (9): ActionBanner, .body, RecentAlertsList, StatusBanners, .body, Color, Date, String (+1 more)

### Community 66 - "Row"
Cohesion: 0.25
Nodes (9): LogbookView, .body, Row, .date, entry, .id, stick, Date (+1 more)

### Community 67 - "SystemServices.swift"
Cohesion: 0.22
Nodes (6): BiometricLock, ProvisioningProfile, Bool, Date, AVFoundation, LocalAuthentication

### Community 68 - ".color"
Cohesion: 0.25
Nodes (6): .body, Color, Double, WidgetColors, GlucoseShared, Int

### Community 69 - "AmbulatoryGlucoseProfile"
Cohesion: 0.36
Nodes (5): AmbulatoryGlucoseProfile, Bin, Calendar, Double, Int

### Community 70 - "TrendArrow"
Cohesion: 0.22
Nodes (8): TrendArrow, falling, fallingQuickly, rising, risingQuickly, stable, .symbol, unknown

### Community 71 - "QuickLogTests"
Cohesion: 0.44
Nodes (3): QuickLogTests, Date, Double

### Community 72 - "OnboardingView"
Cohesion: 0.36
Nodes (5): OnboardingView, .body, .presetDescription, String, Content

### Community 73 - "ScreenshotMode"
Cohesion: 0.33
Nodes (6): Screenshot launch arguments (-screenshots, -onboarding, -tab N), ScreenshotMode, .screen, .tab, Int, String

### Community 74 - ".userNotificationCenter"
Cohesion: 0.33
Nodes (5): Void, UNNotification, UNNotificationPresentationOptions, UNNotificationResponse, UNUserNotificationCenter

### Community 75 - "GlucoseWidgetView"
Cohesion: 0.50
Nodes (4): GlucoseWidgetView, .body, Sparkline, .body

### Community 77 - "CurrentValueCard"
Cohesion: 0.50
Nodes (4): CurrentValueCard, .body, SensorSummaryRow, .body

### Community 79 - "Kind"
Cohesion: 0.67
Nodes (3): Kind, bluetooth, nfc

## Ambiguous Edges - Review These
- `Low/high alert rules (up to 5 each)` → `tools/generate-sounds.ps1`  [AMBIGUOUS]
  README.md · relation: conceptually_related_to
- `App build expiring alert` → `90-day TestFlight build expiry`  [AMBIGUOUS]
  README.md · relation: conceptually_related_to

## Knowledge Gaps
- **218 isolated node(s):** `.screen`, `.tab`, `.unit`, `.latest`, `.decisionLog` (+213 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Low/high alert rules (up to 5 each)` and `tools/generate-sounds.ps1`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `App build expiring alert` and `90-day TestFlight build expiry`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `SensorConnection` connect `SensorConnection` to `GlucoseReading`, `Foundation`, `LibreBLE`, `String`, `View`, `Identifiable`, `AppModel`, `LibreNFCReader`, `.scenePhaseChanged`, `LibreSensorRecord`, `Event`, `.activateSource`, `AppStores`, `Status`?**
  _High betweenness centrality (0.142) - this node is a cross-community bridge._
- **Why does `AppModel` connect `AppModel` to `FingerstickEntry`, `GlucoseReading`, `Foundation`, `RuleEditorView`, `AlertEngine`, `SensorConnection`, `.activateSource`, `GlucoseUnit`, `SurfaceUpdater`, `LogEntry`, `NotificationService`, `QuickLogKind`, `.scenePhaseChanged`, `SoundStyle`, `AppStores`, `.body`, `Row`, `TrendArrow`, `CurrentValueCard`?**
  _High betweenness centrality (0.123) - this node is a cross-community bridge._
- **Why does `GlucoseReading` connect `GlucoseReading` to `FingerstickEntry`, `.reading`, `MissingDataAlert`, `BackupPayload`, `String`, `AppModel`, `ReadingArchive`, `AlertEngine`, `SensorConnection`, `.pdf`, `Sendable`, `AlertRule`, `SurfaceUpdater`, `Hashable`, `Components.swift`, `Identifiable`, `LibreSensorRecord`, `GlucoseChart`, `AmbulatoryGlucoseProfile`?**
  _High betweenness centrality (0.093) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `AppModel` (e.g. with `GlucoseApp` and `NotificationService`) actually correct?**
  _`AppModel` has 14 INFERRED edges - model-reasoned connections that need verification._
- **Are the 4 inferred relationships involving `SensorConnection` (e.g. with `.body` and `.body`) actually correct?**
  _`SensorConnection` has 4 INFERRED edges - model-reasoned connections that need verification._