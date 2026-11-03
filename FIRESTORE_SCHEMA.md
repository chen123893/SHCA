# SHCA Firestore schema

The app uses separate documents for identity, role-specific private profiles,
relationships, medication schedules, medication history, and alerts.

```text
users/{uid}                       account identity and role (owner-only)
elderly_profiles/{uid}            elderly health and emergency information
caregiver_profiles/{uid}          caregiver notification preferences
care_link_lookups/{hashedToken}   exact code/email-hash to elderly ID lookup
care_links/{caregiverId_elderlyId}
medications/{elderlyId_scheduleKey} caregiver-defined active reminder
medication_records/{elderlyId_date_scheduleKey} one dated dose result
emergency_alerts/{alertId}
fall_events/{eventId}
```

`care_links` is the source of truth for caregiver relationships. The old
`linkedElderlyIds` and `linkedCaregiverIds` arrays are read only as a temporary
compatibility fallback and are not written for new links.

`medications` and `medication_records` are intentionally separate rather than
duplicates:

- `medications` stores the current name, strength, integer quantity, reminder
  time, stock, instruction source, and private image reference.
- `medication_records` stores the result for one medicine on one date. Its
  deterministic document ID prevents the current app from creating the same
  medicine/date twice.
- New records contain a `scheduleSnapshot` map so history keeps the original
  medicine name, strength, quantity, instruction, and visual even if the
  current schedule is edited later.
- Legacy duplicate records are collapsed in the app by `recordKey`. They are
  not automatically deleted from Firestore because deletion could discard a
  genuine taken/missed action.

## Existing-account migration

- When an elderly user opens the updated app, legacy health fields are copied
  from `users/{uid}` into `elderly_profiles/{uid}`.
- Legacy caregiver alert settings are copied into `caregiver_profiles/{uid}`.
- Opening the elderly dashboard recreates hashed linking lookups for the
  existing pairing code and registered email.
- Opening the medication page imports existing on-device medication records
  into `medication_records` once when no cloud records exist.
- Existing records without `recordKey` or `scheduleSnapshot` remain readable.
  The updated app adds the new fields when that dated record is next saved.
- Legacy fields are intentionally not deleted automatically. Remove them only
  after confirming all active users have migrated.

Deploy the rules and indexes only after the updated app has been installed and
existing elderly users have opened it once:

```sh
firebase deploy --only firestore:rules,firestore:indexes
```
