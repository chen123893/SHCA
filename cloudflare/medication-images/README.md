# Private medication images and caregiver email reminders

This Worker stores medicine-package photos in a private Cloudflare R2 bucket.
Every upload and download requires a valid Firebase ID token. Uploads are
limited to caregivers with an active `care_links/{caregiverId}_{elderlyId}`
document. The elderly account and its linked caregivers can read the image.

## Deploy

1. Install dependencies: `pnpm install`
2. Sign in from this directory: `pnpm exec wrangler login`
3. Create the bucket: `pnpm exec wrangler r2 bucket create shca-medication-images`
4. Verify the Worker: `pnpm run check`
5. Deploy it: `pnpm run deploy`
6. The deployed production endpoint is:

   `https://shca-medication-images.shca-medication-images.workers.dev`

The Flutter app uses this endpoint by default. It can still be overridden for
another environment with `--dart-define=MEDICATION_IMAGE_API_URL=<url>`.

Do not enable public access on the R2 bucket. The app stores only the returned
private `imageKey` in Firestore. Raw OCR text is not uploaded or saved.

## Free caregiver email reminders

Medication emails use Brevo's transactional email API. The API key is stored
only as a Cloudflare Worker secret and is never included in the Flutter APK.

1. Create a free Brevo account and verify a sender email address.
2. Create a Brevo API key.
3. Save the key securely from this directory:

   `pnpm exec wrangler secret put BREVO_API_KEY`

4. Save the verified sender address as a second Worker secret:

   `pnpm exec wrangler secret put BREVO_SENDER_EMAIL`

   The optional `BREVO_SENDER_NAME` variable defaults to
   `SHCA Medication Reminder`.

5. Run `pnpm run check`, then `pnpm run deploy`.

When a dose is marked missed, the app asks the authenticated Worker to email
linked caregivers who enabled medication email reminders. The Worker verifies
that the matching Firestore record is actually `missed`, sends the elderly
name, medicine name, dosage, instruction, and scheduled time, then stores a
small delivery marker in private R2 to prevent duplicate emails for that dose.
Opening or snoozing an alarm does not send an email.
Medical-condition notes, medicine photos, and OCR text are not emailed.

## Caregiver emergency push

The emergency endpoint verifies the elderly user's Firebase ID token, reads the
new alert and active care links, and sends FCM messages only to registered tokens
belonging to those linked caregivers. It requires the encrypted Cloudflare secret
`FIREBASE_SERVICE_ACCOUNT`.

Production uses the dedicated identity
`shca-push-worker@shca-fyp.iam.gserviceaccount.com` with these predefined roles:

- `roles/datastore.viewer` for reading caregiver preferences and push tokens;
- `roles/cloudmessaging.editor` for sending Firebase Cloud Messaging messages.

Do not put the service-account JSON in the repository or Flutter app. Create or
rotate the key in Google Cloud, then pass the complete JSON directly to:

`pnpm exec wrangler secret put FIREBASE_SERVICE_ACCOUNT`

Run the Worker tests and type check before deploying. FCM authentication failures
return HTTP 503, while invalid or expired individual device tokens are counted as
unavailable without preventing delivery to other registered caregiver devices.
Manual phone/watch SOS and confirmed phone/watch fall alerts each attempt an
idempotent Brevo email to every linked caregiver with a valid email address,
alongside FCM push. Both channels run independently. The response includes
`accepted`/`unavailable` for push and `emailAccepted`/`emailUnavailable` for email;
acceptance does not confirm the caregiver has seen the alert. Missing device
registrations and disabled push preferences return specific explanations.
SMS is not sent by this endpoint.

## Standalone Wear OS endpoints

The Wear OS app signs in directly with Firebase and calls authenticated Worker
routes for account enrollment, today's medication snapshot, activity status,
and medication actions:

- `POST /v1/watch/session`
- `POST /v1/watch/snapshot`
- `POST /v1/watch/activity`
- `POST /v1/watch/medication-action`

SOS and fall events use `POST /v1/watch-emergency`, signed by the watch's
non-exportable Android Keystore RSA key. The watch caches schedules and queues
medicine or emergency actions while temporarily offline.

## Groq statistics forecast

`POST /v1/statistics/forecast` adds a Groq-assisted next-seven-day forecast
to the caregiver statistics page. The Flutter app sends its saved daily counts
to this authenticated Worker. The Worker verifies the active caregiver link,
removes the elderly account ID, and sends only anonymous aggregate counts and
dates to Groq. Names, email addresses, medicine names, diagnoses, photos, and
raw Firestore records are never included in the Groq request.

Create a Groq API key in GroqCloud and save it as an encrypted Worker
secret. Do not put it in `wrangler.jsonc`, a Dart file, or the Android APK:

`pnpm exec wrangler secret put GROQ_API_KEY`

The configured model is `openai/gpt-oss-20b`. Identical forecasts are cached in
private R2 for 12 hours to reduce free-tier usage. The existing on-device,
rule-based outlook remains visible when Groq is not configured, offline, or
rate-limited. AI output is labelled as an estimate and does not diagnose or
claim that a sensor alert is a confirmed fall.

### Phone-approved watch sign-in

`POST /v1/watch/sign-in-token` requires an authenticated elderly account and a valid
watch setup nonce. It verifies the role using the caller's own Firestore permissions,
then signs a five-minute Firebase custom token for that same user ID. Caller-supplied
user IDs are ignored. The phone transfers it only to the paired watch whose displayed
code matched, over Wear OS' authenticated Data Layer. The watch verifies its active nonce,
code and expiry, consumes the setup request after successful sign-in, and keeps refresh
credentials encrypted in Android Keystore. Tokens and passwords must never be logged.
