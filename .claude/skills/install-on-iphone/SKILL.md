---
name: install-on-iphone
description: Get the latest glucose app build onto the user's iPhone from Windows (download the IPA artifact, Sideloadly steps, 7-day expiry). Use when the user wants to install, update or test the app on their phone.
---

# Install on iPhone

1. Find the latest successful iOS build and its artifact:
   ```bash
   /d/Tools/gh/bin/gh.exe run list --workflow ios-build.yml --status success --limit 1
   /d/Tools/gh/bin/gh.exe run download <run-id> --name GlucoseApp-ipa --dir "D:/Projects/Glugose App/builds/<run-id>"
   ```
   `builds/` is git-ignored. Downloading is a file download: tell the user the name and size first.
2. Tell the user to install with **Sideloadly** (https://sideloadly.io). It needs iTunes and iCloud from Apple's website, not the Microsoft Store versions.
   - Drag the `.ipa` in, choose their Apple ID, click Start.
   - On the iPhone: Settings → General → VPN & Device Management → trust the Apple ID, and enable Developer Mode.
3. Remind them:
   - Free Apple ID: the app stops opening after 7 days and must be re-signed. The app warns before it expires.
   - NFC sensor pairing needs the paid Apple Developer Program; a free account can only run the demo sensor.
   - If Sideloadly reports unsupported entitlements on a free account, enable its option to remove them.
4. Screenshots of every screen from the iOS Simulator are attached to each iOS build as the `screenshots` artifact, for a look without installing.
