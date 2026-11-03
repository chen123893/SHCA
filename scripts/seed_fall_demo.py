#!/usr/bin/env python3
"""Add a few explicitly synthetic historical fall events, without dispatching alerts."""
import argparse
import json
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
from seed_medication_demo import Firestore, encode, fingerprint, scalar

ZONE = ZoneInfo('Asia/Kuala_Lumpur')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True)
    parser.add_argument('--elderly-id', required=True)
    parser.add_argument('--caregiver-id', required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    db = Firestore(args.project)
    uid = args.elderly_id
    profile = db.get('elderly_profiles/' + uid)
    link = db.get('care_links/' + args.caregiver_id + '_' + uid)
    if not profile or not link or scalar(link['fields'], 'status') != 'active':
        raise RuntimeError('Profile and active caregiver link must exist.')
    before = db.query('fall_events', 'elderlyId', uid)
    medication_before = db.query('medication_records', 'elderlyId', uid)
    existing_days = {
        datetime.fromisoformat(d['fields']['detectedAt']['timestampValue'].replace('Z', '+00:00'))
        .astimezone(ZONE).date().isoformat()
        for d in before if 'detectedAt' in d['fields'] and scalar(d['fields'], 'isDemo') is not True
    }
    batch = 'shca-fall-demo-2026-10-25-v1'
    scenarios = [
        ('2026-10-03T09:22:00', 'cancelled', 'accidental_detection', 7),
        ('2026-10-09T18:10:00', 'cancelled', 'accidental_detection', 9),
        ('2026-10-14T16:40:00', 'alert_sent', 'simulated_fall', 30),
        ('2026-10-23T12:35:00', 'cancelled', 'accidental_detection', 6),
    ]
    writes = []
    documents = []
    now = datetime.now(ZONE)
    for text, status, scenario, delay in scenarios:
        when = datetime.fromisoformat(text).replace(tzinfo=ZONE)
        if when >= now:
            raise RuntimeError('Demo fall dates must be historical.')
        if when.date().isoformat() in existing_days:
            raise RuntimeError('A chosen demo date already contains a real event; review dates before seeding.')
        path = f'fall_events/demo_{uid}_{when:%Y%m%d}_{scenario}'
        prior = db.get(path)
        if prior:
            if scalar(prior['fields'], 'demoBatchId') != batch:
                raise RuntimeError('A target document exists outside this sample batch.')
            continue
        fields = {
            'elderlyId': uid, 'status': status, 'detectedAt': when,
            'resolvedAt': when + timedelta(seconds=delay),
            'activity': 'DEMO: accidental detection cancelled' if status == 'cancelled'
                        else 'DEMO: simulated fall with alert sent',
            'source': 'demo', 'isDemo': True, 'dataSource': 'synthetic_demo',
            'demoBatchId': batch, 'demoScenario': scenario,
            'notificationDispatched': False,
            'description': 'Synthetic historical example for demonstration; not an actual fall or a dispatched emergency.',
            'createdAt': now,
        }
        doc = {'name': db.prefix + path, 'fields': {key: encode(value) for key, value in fields.items()}}
        documents.append(doc)
        writes.append({'update': doc, 'currentDocument': {'exists': False}})
    month_start = datetime(2026, 10, 1, tzinfo=ZONE)
    real_alerts = sum(scalar(d['fields'], 'status') == 'alert_sent' and
                      datetime.fromisoformat(d['fields']['detectedAt']['timestampValue'].replace('Z', '+00:00')) >= month_start
                      for d in before if scalar(d['fields'], 'isDemo') is not True)
    planned_alerts = sum(scalar(d['fields'], 'status') == 'alert_sent' for d in documents)
    if real_alerts + planned_alerts > 2:
        raise RuntimeError('More than two alert-sent entries would appear; review sample scenarios.')
    manifest = {'project': args.project, 'elderlyId': uid, 'demoBatchId': batch,
                'originalFallEvents': before, 'addedDemoEvents': documents,
                'originalMedicationSha256': fingerprint(medication_before), 'applied': False}
    out = Path(args.manifest)
    out.write_text(json.dumps(manifest, indent=2));out.chmod(0o600)
    print('Profile:', scalar(profile['fields'], 'fullName'))
    print('Original fall events:', len(before), dict(Counter(scalar(d['fields'], 'status') for d in before)))
    print('Sample events to add:', len(documents), dict(Counter(scalar(d['fields'], 'status') for d in documents)))
    print('Sample dates:', ', '.join(d['fields']['detectedAt']['timestampValue'] for d in documents))
    if not args.apply:
        print('Dry run only. No Firestore data changed.');return
    if writes:
        result = db.request(':commit', {'writes': writes})
        assert len(result.get('writeResults', [])) == len(writes)
    after = db.query('fall_events', 'elderlyId', uid)
    original_names = {d['name'] for d in before}
    assert fingerprint(before) == fingerprint([d for d in after if d['name'] in original_names])
    assert len(after) == len(before) + len(documents)
    assert fingerprint(medication_before) == fingerprint(db.query('medication_records', 'elderlyId', uid))
    manifest['applied'] = True
    manifest['verifiedFallEventCount'] = len(after)
    manifest['verifiedStatusCounts'] = dict(Counter(scalar(d['fields'], 'status') for d in after))
    manifest['allOriginalFallEventsUnchanged'] = True
    manifest['medicationHistoryUnchanged'] = True
    out.write_text(json.dumps(manifest, indent=2))
    print('Verified final fall history:', len(after), manifest['verifiedStatusCounts'])
    print('Existing fall events and medication history unchanged. No alert-dispatch endpoint was called.')


if __name__ == '__main__':
    main()
