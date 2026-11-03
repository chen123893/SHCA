# Statistics, Smart Insights and knowledge pages

Statistics is the fifth navigation item for elderly users and caregivers. The
Knowledge & prevention page is available from Statistics and the elderly home.
Caregivers choose a currently linked elderly person before viewing statistics.

## Recorded data and charts

The pages reuse `medication_records` and `fall_events`, with the existing
`elderlyId + scheduledAt/detectedAt descending` Firestore indexes. No schema or
rules changes are needed. Existing owner and active-caregiver read rules apply.

- Today, 7, 30 and 90 calendar-day export ranges, including today, in the
  viewing device's timezone. The on-screen chart keeps the 7, 30 and 90-day
  filters.
- Daily medication completion, medication outcome distribution, daily possible-fall
  alert counts, alert outcome distribution and time-of-day alert counts.
- Only saved doses due by the query time are included. Pending, snoozed and unknown
  statuses remain unresolved; they are not automatically relabelled as missed.
- Legacy medication duplicates collapse by medication ID and local calendar day,
  preferring the latest recorded action. No stored records are modified.
- No records means no observation, not proof of good adherence or absence of falls.
  Sensor alerts are not confirmed falls. Counts are not normalized for monitoring
  time. Live `activity_status` is overwritten, so it cannot support historical
  activity-duration graphs; no activity history is fabricated.
- At most 2,000 records per collection are charted. A larger result prompts the
  user to choose a shorter period rather than silently truncating the totals.
- Offline cached results are labelled.

The next-seven-day completion outlook is a conditional historical baseline, not
a clinical prediction model. It requires at least 7 completed calendar days with
dose records and 14 recorded doses; today's incomplete day is excluded. The 95%
Wilson interval describes uncertainty in the recorded completion rate, not a
calibrated future prediction interval. No forecast of a person's next fall is made.
A 7-day view includes at most 6 complete days, so select 30 or 90 days for an outlook.

## Smart Insights

Smart Insights is fully local and deterministic. It requires no AI account, API
key, subscription or new server deployment. No statistics are sent to Google or
another external AI service.

The panel:

- summarizes saved medication and possible-fall records;
- compares the latest completed window with the preceding equal window when both
  contain at least three recorded days and five doses;
- keeps missed and unresolved medication outcomes separate;
- identifies the time-of-day bucket with the most saved possible-fall alerts;
- labels sensor alerts as possible falls rather than confirmed falls;
- reports Limited, Growing or Strong insight confidence based on record coverage
  and sample size.

The wording is generated from explicit rules in
`lib/models/health_statistics.dart`. It does not diagnose, prescribe, assign a
fall-risk score, or make a clinical claim. This makes the result reproducible and
reviewable while keeping the presentation similar to a polished AI insight card.

## PDF export

Caregivers can choose **Export statistics PDF** from the statistics page and
select Today, Last 7 days, Last 30 days or Last 90 days. The generated A4 report
contains the selected elderly person's overview, detailed totals, daily records,
Smart Insights and the historical completion outlook when enough records exist.
It opens the Android share/save sheet, so the caregiver can save the report or
send it using an installed app. The report uses bundled fonts and is generated
locally; no report data is uploaded to a document service.

## Verification

```sh
flutter analyze --no-pub
flutter test --no-pub
cd cloudflare/medication-images
pnpm run check
node --experimental-transform-types --test test/emergency.test.ts
```

The tests use synthetic records and do not send health data. Widget tests cover
small-phone navigation, the Smart Insights empty state and prevention guidance.

## Prevention source

- https://www.cdc.gov/falls/prevention/index.html
