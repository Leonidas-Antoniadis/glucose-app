# Installing Glucose with TestFlight

TestFlight installs the app over the internet. You don't need a computer, a cable, or anyone's Apple ID password.

> **Not a medical device.** Use Glucose as a second display only. Confirm every value with an approved reader or fingerstick meter before any treatment decision, and keep that backup with you.

## For the tester

### 1. Accept the invitation

You'll get one or two emails from Apple:

1. **"You've been invited to join … on App Store Connect"** (only if you were added as an internal tester). Open it, tap **Accept invitation**, and sign in with your own Apple ID. If you don't get this email, skip this step.
2. **"… has invited you to test Glucose"**. Open this one **on your iPhone**.

### 2. Install

1. Install **TestFlight** from the App Store (it's free, made by Apple).
2. In the invitation email, tap **View in TestFlight**, then **Accept** and **Install**.
   - If you got a code instead of a link: open TestFlight → **Redeem** and type the code.
3. Glucose appears on your home screen with the blue droplet icon.

### 3. First launch

1. Allow **Notifications**. The low and high alerts can't sound without them.
2. Allow **Bluetooth**. The app reads the sensor every minute over Bluetooth.
3. Want to look around first? Turn on the **demo sensor**. It works without a sensor.

### 4. Pair your Libre 2 / Libre 2 Plus sensor

1. Start the sensor with **LibreLink** or the Abbott reader, and wait for its 60-minute warm-up.
2. In Glucose: **Home → sensor icon → Pair sensor (NFC)**, then hold the top of the iPhone against the sensor.
   LibreLink stops giving alarms for that sensor from this point, so set up your alerts in Glucose straight away.
3. Enter a **fingerstick** reading when your glucose is steady, and at least once a day. Until you do, values are rough estimates.
4. Check **Alerts** and make sure at least one low alert is on.

Keep the app running in the background. Don't swipe it closed: iOS restarts it for the sensor, but alerts are most reliable when the app is still open in the background.

### 5. Updates and expiry

- New versions show up in TestFlight. Turn on **Automatic Updates** on the app's TestFlight page.
- Each build stops working **90 days** after it was uploaded. TestFlight shows the days left. Ask for a new build before it runs out.
- Updating keeps your data. Deleting the app erases its readings, settings and logbook, because everything stays on the phone.

### Troubleshooting

| Problem | Fix |
|---|---|
| "The requested app is not available" | The build is still processing or under review. Try again in an hour. |
| Invitation link opens a web page | Install TestFlight first, then tap the link again on the iPhone. |
| No alerts | Settings → Notifications → Glucose → allow, and check that Focus modes aren't silencing it. |
| Pairing fails | Wait until the warm-up is over, keep the phone still on the sensor for a few seconds, and try again. If it still fails, use **Sensor → Share raw sensor captures** and send the file privately. It contains your sensor's ID. |

## For the owner: publishing a build

Do this once:

1. [App Store Connect](https://appstoreconnect.apple.com) → **Apps → + → New App**. Platform iOS, any name, and the **same bundle ID the build is signed with**.
2. **TestFlight** tab → add testers:
   - **Internal** (recommended for family): first invite them under **Users and Access**, then add them to an internal group. Builds are available within minutes and don't need review.
   - **External**: add them by email only. Apple reviews each build first, which usually takes about a day.

Then, for every release:

1. Raise `CURRENT_PROJECT_VERSION` in `App/project.yml`. Every upload needs a new build number.
2. Archive and upload from a Mac:
   ```bash
   xcodegen generate --spec App/project.yml
   cd App
   xcodebuild -project GlucoseApp.xcodeproj -scheme GlucoseApp -configuration Release \
     -destination 'generic/platform=iOS' -archivePath ../build/GlucoseApp.xcarchive \
     -allowProvisioningUpdates DEVELOPMENT_TEAM=<team-id> archive
   xcodebuild -exportArchive -archivePath ../build/GlucoseApp.xcarchive \
     -exportPath ../build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
   ```
   `ExportOptions.plist` needs `method` = `app-store-connect`, `destination` = `upload` and your `teamID`. You can also use Xcode → Product → Archive → **Distribute App → TestFlight & App Store**.
3. When processing finishes (5–15 minutes), the build appears under TestFlight and testers are notified.

Export compliance is already answered in the app (`ITSAppUsesNonExemptEncryption = NO`), so builds don't wait on that question.
