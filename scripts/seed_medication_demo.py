#!/usr/bin/env python3
"""Create explicitly synthetic caregiver demonstration data in Firestore.

Dry run by default. Requires an existing Firebase CLI administrator login.
No passwords, access tokens, or service account files are saved or printed.
"""
import argparse
import hashlib
import json
import random
import shutil
import ssl
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ZONE = ZoneInfo('Asia/Kuala_Lumpur')


def encode(value):
    if value is None:
        return {'nullValue': None}
    if isinstance(value, bool):
        return {'booleanValue': value}
    if isinstance(value, datetime):
        return {'timestampValue': value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')}
    if isinstance(value, int):
        return {'integerValue': str(value)}
    if isinstance(value, str):
        return {'stringValue': value}
    if isinstance(value, list):
        return {'arrayValue': {'values': [encode(item) for item in value]}}
    if isinstance(value, dict):
        return {'mapValue': {'fields': {key: encode(item) for key, item in value.items()}}}
    raise TypeError(type(value).__name__)


def scalar(fields, key):
    value = fields.get(key, {})
    return value.get('stringValue', value.get('booleanValue'))


class Firestore:
    def __init__(self, project):
        binary = shutil.which('firebase') or '/usr/local/bin/firebase'
        refresh = subprocess.run([binary, 'projects:list', '--json'], capture_output=True, text=True)
        if refresh.returncode:
            raise RuntimeError('Refresh your Firebase CLI login before seeding data.')
        login = subprocess.run([binary, 'login:list', '--json'], capture_output=True, text=True, check=True)
        accounts = json.loads(login.stdout)['result']
        if len(accounts) != 1:
            raise RuntimeError('Use exactly one Firebase CLI administrator login for this operation.')
        self._token = accounts[0]['tokens']['access_token']
        self.prefix = f'projects/{project}/databases/(default)/documents/'
        self.base = 'https://firestore.googleapis.com/v1/' + self.prefix.rstrip('/')
        self.context = ssl.create_default_context(cafile='/etc/ssl/cert.pem')

    def request(self, suffix, data=None):
        request = urllib.request.Request(
            self.base + suffix,
            data=None if data is None else json.dumps(data).encode(),
            headers={'Authorization': 'Bearer ' + self._token, 'Content-Type': 'application/json'},
        )
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=40) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and data is None:
                return None
            raise RuntimeError(f'Firestore returned HTTP {error.code}; operation stopped.') from None

    def get(self, path):
        return self.request('/' + path)

    def query(self, collection, field, value):
        rows = self.request(':runQuery', {'structuredQuery': {
            'from': [{'collectionId': collection}],
            'where': {'fieldFilter': {
                'field': {'fieldPath': field}, 'op': 'EQUAL', 'value': encode(value),
            }},
        }})
        return [row['document'] for row in rows if 'document' in row]


def fingerprint(documents):
    content = sorted(documents, key=lambda item: item['name'])
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def build_documents(owner, caregiver, start, end, as_of, batch):
    metadata = {'isDemo': True, 'dataSource': 'synthetic_demo', 'demoBatchId': batch, 'createdAt': as_of}
    documents = {
        f'elderly_profiles/{owner}': {
            'userId': owner, 'fullName': 'Demo Patient — Sample Data',
            'email': 'shca-demo@example.invalid', 'dateOfBirth': '1956-01-01',
            'gender': 'Not specified',
            'emergencyContact': {'phone': '', 'type': 'personal_emergency_contact'},
            'medicalCondition': 'Synthetic demonstration data; not a real patient.',
            **metadata,
        },
        f'care_links/{caregiver}_{owner}': {
            'caregiverId': caregiver, 'elderlyId': owner, 'relationship': 'Demonstration',
            'status': 'active', 'caregiverEmail': '',
            'medicationEmailAlertsEnabled': False, 'linkedAt': as_of, **metadata,
        },
    }
    schedules = []
    for label, hour, visual in [('A', 8, 'tablet'), ('B', 12, 'capsule'), ('C', 16, 'vitamin')]:
        medication = f'demo_medicine_{label.lower()}'
        snapshot = {
            'name': f'Demo Medicine {label}', 'dose': '', 'quantity': 1,
            'instruction': 'Sample instructions for demonstration only.',
            'category': 'Demonstration', 'visual': visual, 'imageKey': '',
            'instructionSource': 'Synthetic demonstration data',
            'recurrence': 'daily', 'startDate': start.isoformat(), 'endDate': end.isoformat(),
            'weekdays': [], 'intervalDays': 1, 'reminderMinutes': [hour * 60],
            'isDemo': True,
        }
        schedule = {
            **snapshot, 'elderlyId': owner, 'scheduleKey': medication,
            'hour': hour, 'minute': 0, 'sourceConfirmed': True,
            'stockRemaining': 90, 'lowStockThreshold': 3,
            'startDate': datetime.combine(start, time(), ZONE),
            'endDate': datetime.combine(end, time(), ZONE),
            'active': True, 'createdByCaregiverId': caregiver, **metadata,
        }
        documents[f'medications/{owner}_{medication}'] = schedule
        schedules.append((medication, hour, snapshot))
    rng = random.Random(20261025)
    day = start
    while day <= end:
        for index, (medication, hour, snapshot) in enumerate(schedules):
            due = datetime.combine(day, time(hour), ZONE)
            if due > as_of:
                continue
            # Deliberately varied synthetic examples to exercise graph states.
            probability = 0.67 if day.day <= 8 else 0.8 if day.day <= 16 else 0.88
            status = 'taken' if rng.random() < probability else 'missed'
            action = min(due + timedelta(minutes=rng.randint(2, 35)), as_of)
            key = f'{day.isoformat()}_{medication}'
            documents[f'medication_records/{owner}_{key}'] = {
                'elderlyId': owner, 'medicationId': medication, 'recordKey': key,
                'scheduledAt': due, 'status': status, 'actionAt': action,
                'snoozedUntil': None, 'scheduleSnapshot': snapshot, **metadata,
            }
        day += timedelta(days=1)
    return documents


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True)
    parser.add_argument('--caregiver-id', required=True)
    parser.add_argument('--preserve-elderly-id', required=True)
    parser.add_argument('--demo-id', default='shca_medication_demo_202610')
    parser.add_argument('--start', default='2026-10-01')
    parser.add_argument('--end', default='2026-10-25')
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    start, end = date.fromisoformat(args.start), date.fromisoformat(args.end)
    now = datetime.now(ZONE)
    if not start <= end <= now.date():
        raise RuntimeError('Demo range must be in the past or today.')
    if not args.demo_id.startswith('shca_medication_demo_') or args.demo_id == args.preserve_elderly_id:
        raise RuntimeError('Only a separate clearly named demo profile can be seeded.')
    batch = f'shca-medication-demo-{end.isoformat()}-v1'
    db = Firestore(args.project)
    caregiver = db.get('users/' + args.caregiver_id)
    if not caregiver or scalar(caregiver['fields'], 'role') != 'caregiver':
        raise RuntimeError('The caregiver account could not be verified.')
    original_records = db.query('medication_records', 'elderlyId', args.preserve_elderly_id)
    original_schedules = db.query('medications', 'elderlyId', args.preserve_elderly_id)
    documents = build_documents(args.demo_id, args.caregiver_id, start, end, now, batch)
    writes = []
    existing = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        prior = dict(zip(documents, pool.map(db.get, documents)))
    for path, values in documents.items():
        previous = prior[path]
        if previous:
            if scalar(previous.get('fields', {}), 'demoBatchId') != batch:
                raise RuntimeError('A document exists outside this demo batch; refusing to overwrite it.')
            existing += 1
            continue
        writes.append({'update': {
            'name': db.prefix + path,
            'fields': {key: encode(value) for key, value in values.items()},
        }, 'currentDocument': {'exists': False}})
    doses = [value for path, value in documents.items() if path.startswith('medication_records/')]
    counts = Counter(dose['status'] for dose in doses)
    manifest = {
        'project': args.project, 'demoProfileId': args.demo_id,
        'displayName': 'Demo Patient — Sample Data', 'batch': batch,
        'start': start.isoformat(), 'end': end.isoformat(),
        'doseCount': len(doses), 'counts': dict(counts),
        'documents': list(documents), 'plannedWrites': writes,
        'existingRealRecordCount': len(original_records),
        'existingRealScheduleCount': len(original_schedules),
        'existingRealRecordsSha256': fingerprint(original_records),
        'existingRealSchedulesSha256': fingerprint(original_schedules),
        'createdAt': now.isoformat(), 'applied': False,
    }
    output = Path(args.manifest)
    output.write_text(json.dumps(manifest, indent=2))
    output.chmod(0o600)
    print(json.dumps({key: manifest[key] for key in [
        'displayName', 'start', 'end', 'doseCount', 'counts',
        'existingRealRecordCount', 'existingRealScheduleCount',
    ]}, indent=2))
    print(f'New documents: {len(writes)}; existing demo documents: {existing}.')
    if not args.apply:
        print('Dry run only. No Firestore data changed.')
        return
    if writes:
        if len(writes) > 450:
            raise RuntimeError('Demo batch is too large for one atomic commit.')
        result = db.request(':commit', {'writes': writes})
        if len(result.get('writeResults', [])) != len(writes):
            raise RuntimeError('Commit acknowledgement did not match the planned write count.')
    actual = db.query('medication_records', 'elderlyId', args.demo_id)
    assert len(actual) == len(doses), 'Demo record count differs from expected.'
    assert all(scalar(doc['fields'], 'isDemo') is True for doc in actual)
    assert fingerprint(original_records) == fingerprint(db.query('medication_records', 'elderlyId', args.preserve_elderly_id))
    assert fingerprint(original_schedules) == fingerprint(db.query('medications', 'elderlyId', args.preserve_elderly_id))
    manifest['applied'] = True
    manifest['verifiedRecordCount'] = len(actual)
    manifest['realDataUnchanged'] = True
    output.write_text(json.dumps(manifest, indent=2))
    print('Verified: demo records present; all original medicine schedules and history unchanged.')


if __name__ == '__main__':
    main()
