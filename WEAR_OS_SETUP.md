# SHCA Wear OS companion

The `wear_app` Flutter project is the SHCA smartwatch application. Flutter owns
the interface, 50 Hz sensor processing, and verified wrist TFLite model. A
small Kotlin bridge exchanges activity results, confirmed emergency events,
and medication actions with the Flutter phone app and schedules native alarms.

## Requirements

- A Wear OS watch (for example, Galaxy Watch4 or newer). Older Samsung Tizen
  watches cannot run this module.
- The watch and Android phone must be paired.
- The phone and watch builds must use the same `com.shca.shca` application ID
  and signing certificate. The debug builds already meet this requirement when
  both are built on this computer.

## Run from Android Studio

1. Open `SHCA` for the phone app and `SHCA/wear_app` for the watch app.
2. Connect the Samsung phone normally.
3. Enable Developer options and wireless debugging on the Wear OS watch, then
   pair it in Android Studio's Device Manager.
4. Run the main SHCA Flutter app on the phone. Run `wear_app/lib/main.dart` on
   the watch.
5. Allow notifications/alarms on the watch. Open the elderly dashboard on the
   phone once so the next medication can sync.

The phone's watch status is based on the `shca_watch_app` Wear OS capability,
which the companion app advertises. This prevents another connected Wear OS
device or unrelated watch app from being shown as SHCA. Connect, disconnect and
capability changes update the phone while the dashboard is open; pull-to-refresh
also performs a fresh check.

## Real-device validation

The training recordings were captured from a Fitbit Sense at about 50 Hz. Test
the exported model on the actual target watch before demonstrating automated
fall alerts. Wear the watch snugly in the same wrist position and collect a
short calibration set for walking, sitting/standing, arm activity, exercise,
stumbles, and carefully supervised staged falls. Keep the 15-second “I'm safe”
confirmation because this model is a prototype rather than a medical device.

## Sign in using the phone (recommended)

1. Install matching updated SHCA apps on the paired Android phone and watch.
2. On the watch, choose **Connect with phone**. Its six-digit code lasts five minutes.
3. Sign in to the **elderly account** on the phone, then open **Profile → Connect smartwatch**.
4. Enter the watch code and confirm **Connect watch**. The phone shows the account name
   before approval; the watch opens its home screen after completing Firebase sign-in.
5. After setup the watch uses its own encrypted Firebase session and internet connection.
   The phone does not need to remain nearby for cloud sync, SOS, or fall alerts.

Both devices must be paired through Wear OS/Bluetooth during code setup. Setup uses
Wear OS Data Layer messages restricted to the same application ID and signing certificate.
The worker only issues a short-lived token for the authenticated elderly user's own account.
No password is transferred between devices. Expired, cancelled, or consumed watch codes
cannot approve another sign-in. No extra paid service is introduced.

**Use email instead** remains available when a paired phone is not accessible. Tapping
Email or Password opens a native watch editor; the email editor includes an explicit
**@** button. Press **Done** to return the edited value to the SHCA sign-in form.

Release builds preserve `android_wear_capabilities` with `res/raw/shca_keep.xml`:
Play services loads the array by name, so it otherwise appears unused to the resource
shrinker. The watch also registers `shca_watch_app` when its main activity opens.

Hardware signing keys are scoped to the signed-in elderly account. Connecting the same
physical watch to another elderly profile creates a distinct key/enrollment; it does not
reassign or overwrite the previous profile's protected credential. Signing out clears
pending direct-emergency retries from the previous session.

## Background fall confirmation

Foreground model detections and background wrist detections both create the same native
15-second confirmation. SHCA shows a full-screen watch pop-up with **I'm safe** and
**Send alert**; no caregiver push/email or phone emergency request is created while the
countdown is pending. Safe cancels it; Send alert or no response at the original deadline
queues the existing direct-cloud and paired-phone fallback using one shared event ID.
The deadline is persisted and also scheduled with AlarmManager where exact alarms are
allowed, so reopening the app does not restart the countdown. Sign-out cancels pending
confirmations. Existing server idempotency prevents duplicate notifications on retries.

The watch needs **Appear on top** access for the pop-up while other screens are open.
Use **Activity → Enable fall pop-ups** on the watch. Some Wear OS versions do not expose
this setting; during developer installation the equivalent setup command is:

`adb -s <watch-address> shell appops set com.shca.shca SYSTEM_ALERT_WINDOW allow`

A high-priority notification also provides safe/send actions. No SMS integration is added.
The debug-only `com.shca.shca.PREVIEW_FALL_CONFIRMATION` intent opens a local preview after
three seconds. Its timeout and buttons never dispatch cloud or phone caregiver alerts;
production builds ignore this test intent and clear leftover preview confirmations.
