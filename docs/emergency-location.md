# Emergency location sharing

On the elderly phone, open Profile → Emergency Information and enable **Share location in fall and SOS alerts**. On the watch, open Activity → **Share alert location**. Each device/account starts with sharing off. Accept Android location permission. For screen-off alerts, use the settings link and choose Location → Allow all the time; approximate permission is supported.

Confirmed falls and SOS requests use the same location flow. Each device takes a bounded, one-shot location read, with up to six seconds to acquire a fix. There is no continuous tracking. Cached fixes older than two minutes are labelled last known; fixes older than 24 hours are omitted. Alert records keep the source device, measurement time and accuracy. Permission denied, GPS unavailable or no fix produces an alert without location. The existing emergency-contact call is requested independently.

Linked caregivers receive plain coordinates, source, time and accuracy in a single SMS. Maps links stay in email and the caregiver alert page. Malaysian carriers block SMS containing URLs under the MCMC directive, so SMS deliberately contains no hyperlink or callback number. See https://www.business.maxis.com.my/en/faq/data-internet/sms-content-blocking/. Push data includes the Maps URL, capture time and source; the lock-screen notification stays generic, and opening the alert shows the location card. SMS still requires the existing elderly/caregiver SMS opt-ins, phone permission and active SIM. A successful SMS callback means carrier acceptance, not confirmed recipient delivery. Caregivers must be actively linked and listed on the alert to read its location. Removing a link removes access to saved emergency alerts.

The watch sends a signed location snapshot over its own connection. The paired phone can use its own location if it relays the request. Whichever path stores the alert first supplies that alert’s snapshot; a missing location may be filled once by the elderly account or its signed watch request. SMS can use the phone snapshot while the watch path is still sending. An early push/email may have no location if neither device had a fix when it was delivered; check the alert page for a later phone fallback. Retries do not continuously update the watch/phone fall snapshot.

## Verification

Run the normal phone/watch Flutter tests, native phone/watch Gradle tests, and `node --test test/*.test.ts` in `cloudflare/medication-images`. Type-check the Worker with `node node_modules/typescript/bin/tsc --noEmit`.

For the database checks, start a Firestore emulator on 127.0.0.1:8185 with project `demo-shca-location` and these Firestore rules, then run `python3 test/firestore_emergency_location_rules.py`. It uses only dummy emulator data, covering invalid coordinates/age, owner-only location fill, linked/removed caregivers and resolving located alerts. Never point this test at production.
