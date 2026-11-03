# SHCA Watch

Standalone Wear OS safety and medication app for an elderly SHCA account.

## Account and connectivity

On first launch, sign in with the same elderly email and password used by the
SHCA phone app. The Firebase session is encrypted with an Android Keystore key.
The watch then enrolls its non-exportable RSA device key with the SHCA Worker.

After sign-in, the watch can use its own Wi-Fi or LTE connection to:

- publish live wrist activity;
- download and cache today's medicine schedule;
- save Taken and Snoozed responses;
- send SOS and detected-fall alerts directly to linked caregivers; and
- retry queued medicine and emergency events after a temporary outage.

The Wear OS data layer is retained as an optional phone fallback. Immediate
caregiver delivery still requires internet access through Wi-Fi, LTE, or the
watch's shared Bluetooth internet connection.

## Build

```sh
/Users/zichen/develop/flutter/bin/flutter pub get
/Users/zichen/develop/flutter/bin/flutter build apk --debug
```

The APK is created at `build/app/outputs/flutter-apk/app-debug.apk`.
