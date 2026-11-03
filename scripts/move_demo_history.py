#!/usr/bin/env python3
"""Move a tagged sample batch into an existing profile, filling empty days only.

No active medicine schedules or existing history on the target are changed.
The source sample profile is removed in the same atomic commit.
"""
import argparse
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from seed_medication_demo import Firestore, scalar, fingerprint

ZONE = ZoneInfo('Asia/Kuala_Lumpur')


def local_day(document):
    value = document['fields']['scheduledAt']['timestampValue']
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(ZONE).date().isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True)
    parser.add_argument('--target-elderly-id', required=True)
    parser.add_argument('--caregiver-id', required=True)
    parser.add_argument('--source-manifest', required=True)
    parser.add_argument('--backup', required=True)
    parser.add_argument('--through', default='2026-10-24')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    prior = json.loads(Path(args.source_manifest).read_text())
    source_id = prior['demoProfileId']
    assert source_id.startswith('shca_medication_demo_')
    assert source_id != args.target_elderly_id
    db = Firestore(args.project)
    profile = db.get('elderly_profiles/' + args.target_elderly_id)
    if not profile:
        raise RuntimeError('Target profile does not exist.')
    link = db.get('care_links/' + args.caregiver_id + '_' + args.target_elderly_id)
    if not link or scalar(link['fields'], 'status') != 'active':
        raise RuntimeError('The caregiver is not actively linked to the target.')
    target_records = db.query('medication_records', 'elderlyId', args.target_elderly_id)
    target_schedules = db.query('medications', 'elderlyId', args.target_elderly_id)
    original_records = [d for d in target_records if scalar(d['fields'], 'isDemo') is not True]
    occupied = {local_day(d) for d in original_records}
    source_records = db.query('medication_records', 'elderlyId', source_id)
    source_schedules = db.query('medications', 'elderlyId', source_id)
    owned_paths = {d['name'].removeprefix(db.prefix) for d in source_records + source_schedules}
    expected = {p for p in prior['documents'] if p.startswith(('medication_records/', 'medications/'))}
    if owned_paths != expected:
        raise RuntimeError('Source profile contains unexpected changes; refusing cleanup.')
    with ThreadPoolExecutor(max_workers=8) as pool:
        source_documents = list(pool.map(db.get, prior['documents']))
    if any(d is None or scalar(d['fields'], 'demoBatchId') != prior['batch'] or
           scalar(d['fields'], 'isDemo') is not True for d in source_documents):
        raise RuntimeError('Source documents no longer match the original demo batch.')
    samples = []
    writes = []
    for source in source_records:
        day = local_day(source)
        if day > args.through or day in occupied:
            continue
        fields = json.loads(json.dumps(source['fields']))
        fields['elderlyId'] = {'stringValue': args.target_elderly_id}
        fields['demoOriginProfileId'] = {'stringValue': source_id}
        fields['demoMigrationBatch'] = {'stringValue': 'existing-profile-empty-days-2026-10-25-v1'}
        snapshot = fields['scheduleSnapshot']['mapValue']['fields']
        snapshot['endDate'] = {'stringValue': args.through}
        record_key = fields['recordKey']['stringValue']
        path = 'medication_records/' + args.target_elderly_id + '_' + record_key
        if any(d['name'] == db.prefix + path for d in target_records):
            raise RuntimeError('A sample target already exists; no records were changed.')
        document = {'name': db.prefix + path, 'fields': fields}
        samples.append(document)
        writes.append({'update': document, 'currentDocument': {'exists': False}})
    if not samples:
        raise RuntimeError('No empty dates need demonstration history.')
    for source in source_documents:
        writes.append({'delete': source['name'], 'currentDocument': {'updateTime': source['updateTime']}})
    backup = {
        'project': args.project,
        'targetElderlyId': args.target_elderly_id,
        'sourceProfileId': source_id,
        'originalTargetHistory': target_records,
        'originalTargetSchedules': target_schedules,
        'removedSourceDocuments': source_documents,
        'addedTargetSamples': samples,
        'preservedExistingDays': sorted(occupied),
        'applied': False,
    }
    out = Path(args.backup)
    out.write_text(json.dumps(backup, indent=2));out.chmod(0o600)
    counts = Counter(scalar(d['fields'], 'status') for d in samples)
    days = sorted({local_day(d) for d in samples})
    print('Target:', scalar(profile['fields'], 'fullName'))
    print('New labeled sample records:', len(samples), dict(counts))
    print('Previously empty dates filled:', ', '.join(days))
    print('Original records preserved:', len(target_records))
    print('Original active medicine schedules preserved:', len(target_schedules))
    print('Source demo documents to remove:', len(source_documents))
    if not args.apply:
        print('Dry run only. No Firestore data changed.');return
    if len(writes) > 450:
        raise RuntimeError('Migration is too large for one atomic commit.')
    result = db.request(':commit', {'writes': writes})
    assert len(result.get('writeResults', [])) == len(writes)
    after = db.query('medication_records', 'elderlyId', args.target_elderly_id)
    names = {d['name'] for d in target_records}
    assert fingerprint(target_records) == fingerprint([d for d in after if d['name'] in names])
    assert fingerprint(target_schedules) == fingerprint(db.query('medications', 'elderlyId', args.target_elderly_id))
    assert len(after) == len(target_records) + len(samples)
    assert db.get('elderly_profiles/' + source_id) is None
    assert db.get('care_links/' + args.caregiver_id + '_' + source_id) is None
    assert not db.query('medication_records', 'elderlyId', source_id)
    assert not db.query('medications', 'elderlyId', source_id)
    covered = {local_day(d) for d in after if local_day(d).startswith('2026-10-') and local_day(d) <= args.through}
    assert all(f'2026-10-{i:02d}' in covered for i in range(1, 25))
    backup['applied'] = True
    backup['verifiedTargetRecordCount'] = len(after)
    backup['allOriginalRecordsUnchanged'] = True
    backup['sourceDemoRemoved'] = True
    out.write_text(json.dumps(backup, indent=2))
    print('Verified: all 1–24 October dates now have records; original data unchanged; separate Demo Patient removed.')


if __name__ == '__main__':
    main()
