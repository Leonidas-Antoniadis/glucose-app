# Installing Glucose with TestFlight

TestFlight installs the app over the internet. You don't need a computer, a cable, or anyone's Apple ID password.

> **Not a medical device.** Use Glucose as a second display only. Confirm every value with an approved reader or fingerstick meter before any treatment decision, and keep that backup with you.

> **Family only.** Share builds only with people on your own Apple Developer team (internal testers). Giving glucose software to others can bring medical-device rules into play, and external testing needs Apple's review, which an unofficial CGM app is unlikely to pass.

## For the tester

### 1. Accept the invitation

You'll get two emails from Apple:

1. **"You've been invited to join … on App Store Connect"**. Open it, tap **Accept invitation**, and sign in with your own Apple ID.
2. **"… has invited you to test Glucose"**. Open this one **on your iPhone**.

### 2. Install

1. Install **TestFlight** from the App Store (it's free, made by Apple).
2. In the invitation email, tap **View in TestFlight**, then **Accept** and **Install**.
3. Glucose appears on your home screen with the blue droplet icon.

### 3. First launch

1. Read the safety notice, choose your units and an alert preset.
2. Allow **Notifications**. The low and high alerts can't sound without them.
3. Want to look around first? Choose the **demo sensor**. It works without a sensor.

### 4. Pair your Libre 2 / Libre 2 Plus sensor (EU)

1. Start the sensor with **LibreLink** or the Abbott reader. You can pair during its 60-minute warm-up; you'll get a "Sensor ready" notification when it ends. A sensor that's already running needs no new warm-up.
2. In Glucose: **Home → sensor icon → Pair sensor (NFC)**, then hold the top of the iPhone against the sensor. Allow **Bluetooth** when asked.
   - The app first checks that it can read your sensor. If it can't, nothing changes and LibreLink keeps working.
   - Once paired, LibreLink stops giving alarms for that sensor, so check your alerts in Glucose straight away.
   - To go back to LibreLink, scan the sensor with LibreLink. Glucose then shows "No reading" with a **Pair again** button.
3. Enter a **blood glucose** value (fingerstick) when your glucose is steady, and at least once a day. Until you do, values are rough estimates.
4. Check **Alerts** and make sure at least one low alert at or below 60 mg/dL is on.

**Don't swipe the app closed.** If you do, iOS won't relaunch it: readings and alerts stop until you open it again. Leaving it in the background is fine; iOS wakes it for each reading. After restarting the phone, open the app once.

### 5. Updates and expiry

- New versions show up in TestFlight. Turn on **Automatic Updates** on the app's TestFlight page.
- Each build stops working **90 days** after it was uploaded. TestFlight shows the days left. If the app hasn't changed for 30 days, a fresh copy of the same version is uploaded automatically, so with Automatic Updates on it never runs out.
- Updating keeps your data. Deleting the app erases its readings, settings and logbook, because everything stays on the phone.

### Troubleshooting

| Problem | Fix |
|---|---|
| "The requested app is not available" | The build is still processing. Try again in 15 minutes. |
| Invitation link opens a web page | Install TestFlight first, then tap the link again on the iPhone. |
| No alerts | Settings → Notifications → Glucose → allow, and check that Focus modes aren't silencing it. |
| "No reading since …" | Keep the phone within a few meters of the sensor. If LibreLink was used to scan the sensor, tap **Pair again**. Tap **Scan sensor** to fill the gap (the sensor keeps 8 hours). |
| Pairing fails | Hold the phone still on the sensor for a few seconds and try again. If it keeps failing, open **Sensor → Raw sensor data**: the failed read is kept there. Tap **Prepare file to share** and send it privately. It contains your sensor's ID. |

## For the owner: publishing a build

The owner is whoever has the paid Apple Developer Program membership.

### Once

1. [App Store Connect](https://appstoreconnect.apple.com) → **Apps → + → New App**. Platform iOS, any name, and the bundle ID uploads are built with. The app is set up as **NCA Glucose** with **com.ncatechsolutions.glucoseapp**.
   Uploads swap only the two `PRODUCT_BUNDLE_IDENTIFIER` values in `App/project.yml` for that ID (the widget gets the same plus `.widget`). The app group stays `group.com.leonidasantoniadis.glucoseapp`, which the code uses. To use another app record, change `BUNDLE_ID` in `.github/workflows/testflight.yml`, or pass `BUNDLE_ID=…` to the script.
2. **Users and Access** → invite each family member with their own Apple ID.
3. **TestFlight** tab → create an **internal** group with **automatic distribution** and add them (ours is **Family**). Internal builds are available within minutes and don't need Apple's review.

### Every release, from a Mac

1. Install Xcode and sign in under **Xcode → Settings → Accounts** with the developer account.
2. In a terminal, in this repository:
   ```bash
   git pull
   ./tools/testflight-upload.sh YOUR_TEAM_ID
   ```
   Your Team ID is on [developer.apple.com/account](https://developer.apple.com/account) → **Membership**. The script installs XcodeGen if needed, gives the build a new number automatically, archives with automatic signing (it registers NFC, notifications and the app group for you), and uploads.
3. When processing finishes (5-15 minutes), the build appears under TestFlight and testers are notified.

### Every release, automatically from GitHub

The **TestFlight upload** workflow uploads a new build on every push to `main` that changes `App/`, `Packages/` or the workflow. Testers in the automatic-distribution group get it in TestFlight 5-15 minutes later. You can also run it by hand: **Actions → TestFlight upload → Run workflow**. It needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Where to find it |
|---|---|
| `APPLE_TEAM_ID` | developer.apple.com/account → Membership |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → create a key with the **Admin** role |
| `ASC_KEY_P8` | The contents of the downloaded `.p8` file (it can only be downloaded once) |
| `BUILD_CERT_P12` | Base64 of an **Apple Development** certificate with its private key (`.p12`), used to sign the archive |
| `BUILD_CERT_PASSWORD` | The password of that `.p12` |

Distribution signing uses Apple's cloud-managed certificate through the API key. The stored development certificate stops Xcode from creating a new one on every run (Apple limits how many a team can have). It expires after a year: create a new one and replace both `BUILD_CERT_` secrets.

Export compliance is already answered in the app (`ITSAppUsesNonExemptEncryption = NO`), so builds don't wait on that question.

Builds expire 90 days after upload. When the app doesn't change for a while, the **TestFlight refresh** workflow keeps them fresh: every Monday it starts the TestFlight upload if the last successful one is 30 or more days old. The same code goes up with a new build number, and testers' phones install it like any other update. It uses no extra secrets.
