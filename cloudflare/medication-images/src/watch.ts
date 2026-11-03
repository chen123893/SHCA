interface WatchEnv {
  MEDICATION_IMAGES: R2Bucket;
  FIREBASE_PROJECT_ID: string;
}

interface FirestoreValue {
  stringValue?: string;
  booleanValue?: boolean;
  integerValue?: string;
  doubleValue?: number;
  timestampValue?: string;
  arrayValue?: { values?: FirestoreValue[] };
  mapValue?: { fields?: Record<string, FirestoreValue> };
  nullValue?: null;
}

interface FirestoreDocument {
  name?: string;
  updateTime?: string;
  fields?: Record<string, FirestoreValue>;
}

interface ConditionalWrite {
  update: { name: string; fields: Record<string, FirestoreValue> };
  updateMask: { fieldPaths: string[] };
  currentDocument: { exists: false } | { updateTime: string };
}

class MedicationCommitError extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`Firestore medication commit failed: ${status}`);
    this.status = status;
  }
}

function documentVersion(document: FirestoreDocument | null): ConditionalWrite['currentDocument'] {
  if (!document) return { exists: false };
  if (!document.updateTime) throw new Error('Firestore document version is missing.');
  return { updateTime: document.updateTime };
}

async function commitMedicationWrites(
  env: WatchEnv,
  token: string,
  writes: ConditionalWrite[],
): Promise<boolean> {
  const response = await fetch(`${base(env)}/documents:commit`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ writes }),
  });
  if (response.ok) return true;
  const error = await response.json().catch(() => null) as { error?: { status?: string } } | null;
  if (response.status === 409 || response.status === 412 ||
      ['ABORTED', 'FAILED_PRECONDITION', 'ALREADY_EXISTS'].includes(error?.error?.status ?? '')) {
    return false;
  }
  throw new MedicationCommitError(response.status);
}

const credentialPattern = /^[a-f0-9]{40}$/;
const identifierPattern = /^[A-Za-z0-9_-]{1,128}$/;

function reply(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function base(env: WatchEnv): string {
  return `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID)}/databases/(default)`;
}

async function readDocument(
  env: WatchEnv,
  path: string,
  token: string,
): Promise<FirestoreDocument | null> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  const response = await fetch(`${base(env)}/documents/${encoded}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Firestore read failed: ${response.status}`);
  return await response.json() as FirestoreDocument;
}

async function queryDocuments(
  env: WatchEnv,
  collection: string,
  field: string,
  value: string,
  token: string,
): Promise<FirestoreDocument[]> {
  const response = await fetch(`${base(env)}/documents:runQuery`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: collection }],
        where: {
          fieldFilter: {
            field: { fieldPath: field },
            op: "EQUAL",
            value: { stringValue: value },
          },
        },
      },
    }),
  });
  if (!response.ok) throw new Error(`Firestore query failed: ${response.status}`);
  const rows = await response.json() as Array<{ document?: FirestoreDocument }>;
  return rows.flatMap(row => row.document ? [row.document] : []);
}

async function writeDocument(
  env: WatchEnv,
  path: string,
  fields: Record<string, FirestoreValue>,
  token: string,
  updateMask: string[] = [],
): Promise<void> {
  const encoded = path.split("/").map(encodeURIComponent).join("/");
  const params = new URLSearchParams();
  updateMask.forEach(field => params.append("updateMask.fieldPaths", field));
  const suffix = params.size > 0 ? `?${params}` : "";
  const response = await fetch(`${base(env)}/documents/${encoded}${suffix}`, {
    method: "PATCH",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ fields }),
  });
  if (!response.ok) throw new Error(`Firestore write failed: ${response.status}`);
}

function stringField(fields: Record<string, FirestoreValue> | undefined, key: string): string {
  return fields?.[key]?.stringValue?.trim() ?? "";
}

function intField(fields: Record<string, FirestoreValue> | undefined, key: string, fallback = 0): number {
  const value = Number(fields?.[key]?.integerValue ?? fields?.[key]?.doubleValue);
  return Number.isFinite(value) ? Math.trunc(value) : fallback;
}

function stringValue(value: string): FirestoreValue {
  return { stringValue: value };
}

function integerValue(value: number): FirestoreValue {
  return { integerValue: String(Math.trunc(value)) };
}

function localDate(timestamp: string | undefined, offsetMinutes: number): string {
  if (!timestamp) return "";
  const time = Date.parse(timestamp);
  if (!Number.isFinite(time)) return "";
  return new Date(time + offsetMinutes * 60_000).toISOString().slice(0, 10);
}

function daysBetween(first: string, second: string): number {
  return Math.floor((Date.parse(`${second}T00:00:00Z`) - Date.parse(`${first}T00:00:00Z`)) / 86_400_000);
}

function scheduledOn(
  fields: Record<string, FirestoreValue>,
  date: string,
  offsetMinutes: number,
): boolean {
  if (fields.active?.booleanValue === false) return false;
  const recurrence = stringField(fields, "recurrence") || "daily";
  if (recurrence === "asNeeded") return false;
  const start = localDate(fields.startDate?.timestampValue, offsetMinutes);
  const end = localDate(fields.endDate?.timestampValue, offsetMinutes);
  if (start && date < start) return false;
  if (end && date > end) return false;
  if (recurrence === "oneTime") return start.length > 0 && start === date;
  if (recurrence === "selectedDays") {
    const day = new Date(`${date}T00:00:00Z`).getUTCDay() || 7;
    const weekdays = fields.weekdays?.arrayValue?.values?.map(value =>
      Number(value.integerValue)
    ) ?? [];
    return weekdays.includes(day);
  }
  if (recurrence === "intervalDays" && start) {
    const interval = Math.max(1, intField(fields, "intervalDays", 1));
    return daysBetween(start, date) % interval === 0;
  }
  return true;
}

function doseSummary(fields: Record<string, FirestoreValue>): string {
  const raw = stringField(fields, "dose");
  const quantity = Math.max(1, intField(fields, "quantity", 1));
  const visual = stringField(fields, "visual").toLowerCase();
  const unit = visual === "capsule" ? "capsule" : visual === "liquid" ? "dose" : "tablet";
  const quantityText = `${quantity} ${unit}${quantity === 1 ? "" : "s"}`;
  return !raw || /^\s*\d+\s*(tablets?|capsules?|doses?)\s*$/i.test(raw)
    ? quantityText
    : `${raw} • ${quantityText}`;
}

function scheduleSnapshot(fields: Record<string, FirestoreValue>): FirestoreValue {
  const keys = [
    "name", "dose", "quantity", "instruction", "category", "visual",
    "imageKey", "instructionSource", "recurrence", "startDate", "endDate",
    "weekdays", "intervalDays",
  ];
  return {
    mapValue: {
      fields: Object.fromEntries(keys.flatMap(key => fields[key] ? [[key, fields[key]]] : [])),
    },
  };
}

async function requireElderly(
  env: WatchEnv,
  uid: string,
  token: string,
): Promise<FirestoreDocument | null> {
  const user = await readDocument(env, `users/${uid}`, token);
  return stringField(user?.fields, "role") === "elderly" ? user : null;
}

export async function openWatchSession(
  request: Request,
  env: WatchEnv,
  uid: string,
  token: string,
): Promise<Response> {
  try {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const credentialId = typeof body?.credentialId === "string" ? body.credentialId : "";
    const publicKey = typeof body?.publicKey === "string" ? body.publicKey : "";
    if (!credentialPattern.test(credentialId) || publicKey.length < 300 || publicKey.length > 1000) {
      return reply({ error: "The watch identity is invalid." }, 400);
    }
    const user = await requireElderly(env, uid, token);
    if (!user) return reply({ error: "Sign in with the elderly account on this watch." }, 403);
    await writeDocument(env, `watch_credentials/${credentialId}`, {
      keyId: stringValue(credentialId),
      elderlyId: stringValue(uid),
      algorithm: stringValue("RS256"),
      publicKey: stringValue(publicKey),
      active: { booleanValue: true },
      updatedAt: { timestampValue: new Date().toISOString() },
    }, token);
    const profile = await readDocument(env, `elderly_profiles/${uid}`, token);
    const name = stringField(profile?.fields, "fullName") ||
      stringField(user.fields, "fullName") || "Elderly user";
    return reply({ active: true, elderlyId: uid, name });
  } catch (error) {
    console.error("Watch session failed", error);
    return reply({ error: "The watch could not finish secure sign-in." }, 502);
  }
}

export async function watchSnapshot(
  request: Request,
  env: WatchEnv,
  uid: string,
  token: string,
): Promise<Response> {
  try {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const date = typeof body?.date === "string" ? body.date : "";
    const offsetMinutes = typeof body?.offsetMinutes === "number"
      ? Math.trunc(body.offsetMinutes)
      : 0;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || offsetMinutes < -840 || offsetMinutes > 840) {
      return reply({ error: "The watch date is invalid." }, 400);
    }
    const user = await requireElderly(env, uid, token);
    if (!user) return reply({ error: "This watch account is unavailable." }, 403);
    const schedules = await queryDocuments(env, "medications", "elderlyId", uid, token);
    const medications: Record<string, unknown>[] = [];
    for (const schedule of schedules) {
      const fields = schedule.fields ?? {};
      const id = stringField(fields, "scheduleKey");
      if (!identifierPattern.test(id) || !scheduledOn(fields, date, offsetMinutes)) continue;
      const occurrenceId = `${date}_${id}`;
      const record = await readDocument(env, `medication_records/${uid}_${occurrenceId}`, token);
      const status = stringField(record?.fields, "status") || "pending";
      if (status === "taken" || status === "missed") continue;
      const [year, month, day] = date.split("-").map(Number);
      const hour = Math.max(0, Math.min(23, intField(fields, "hour", 8)));
      const minute = Math.max(0, Math.min(59, intField(fields, "minute", 0)));
      const scheduledAt = Date.UTC(year, month - 1, day, hour, minute) - offsetMinutes * 60_000;
      const snoozed = Date.parse(record?.fields?.snoozedUntil?.timestampValue ?? "");
      medications.push({
        id,
        occurrenceId,
        name: stringField(fields, "name") || "Medicine",
        dose: doseSummary(fields),
        instruction: stringField(fields, "instruction"),
        scheduledAt,
        remindAt: Number.isFinite(snoozed) ? snoozed : scheduledAt,
        status,
      });
    }
    medications.sort((a, b) => Number(a.remindAt) - Number(b.remindAt));
    const profile = await readDocument(env, `elderly_profiles/${uid}`, token);
    return reply({
      elderlyId: uid,
      name: stringField(profile?.fields, "fullName") || stringField(user.fields, "fullName") || "Elderly user",
      medications,
      syncedAt: Date.now(),
    });
  } catch (error) {
    console.error("Watch snapshot failed", error);
    return reply({ error: "The watch could not refresh its data." }, 502);
  }
}

export async function saveWatchActivity(
  request: Request,
  env: WatchEnv,
  uid: string,
  token: string,
): Promise<Response> {
  try {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const label = typeof body?.label === "string" ? body.label.trim().slice(0, 80) : "";
    const confidence = typeof body?.confidence === "number" ? body.confidence : 0;
    const fallProbability = typeof body?.fallProbability === "number" ? body.fallProbability : 0;
    const measuredAt = typeof body?.updatedAt === "number" ? body.updatedAt : 0;
    if (!label || !Number.isSafeInteger(measuredAt) || Math.abs(Date.now() - measuredAt) > 10 * 60_000) {
      return reply({ error: "The activity update is invalid." }, 400);
    }
    if (!await requireElderly(env, uid, token)) {
      return reply({ error: "This watch account is unavailable." }, 403);
    }
    await writeDocument(env, `activity_status/${uid}`, {
      elderlyId: stringValue(uid),
      watch: {
        mapValue: { fields: {
          label: stringValue(label),
          confidence: { doubleValue: Math.max(0, Math.min(1, confidence)) },
          fallProbability: { doubleValue: Math.max(0, Math.min(1, fallProbability)) },
          possibleFall: { booleanValue: body?.possibleFall === true },
          active: { booleanValue: true },
          measuredAt: { timestampValue: new Date(measuredAt).toISOString() },
          publishedAt: { timestampValue: new Date().toISOString() },
        } },
      },
      updatedAt: { timestampValue: new Date().toISOString() },
    }, token, ["elderlyId", "watch", "updatedAt"]);
    return reply({ saved: true });
  } catch (error) {
    console.error("Watch activity failed", error);
    return reply({ error: "The activity update will retry when online." }, 502);
  }
}

export async function saveWatchMedicationAction(
  request: Request,
  env: WatchEnv,
  uid: string,
  token: string,
): Promise<Response> {
  let lockKey = "";
  let lockAcquired = false;
  try {
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    const eventId = typeof body?.eventId === "string" ? body.eventId : "";
    const medicationId = typeof body?.medicationId === "string" ? body.medicationId : "";
    const occurrenceId = typeof body?.occurrenceId === "string" ? body.occurrenceId : "";
    const action = body?.action;
    const scheduledAt = typeof body?.scheduledAt === "number" ? body.scheduledAt : 0;
    const createdAt = typeof body?.createdAt === "number" ? body.createdAt : 0;
    const remindAt = typeof body?.remindAt === "number" ? body.remindAt : 0;
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(eventId) || !identifierPattern.test(medicationId) ||
        !/^\d{4}-\d{2}-\d{2}_[A-Za-z0-9_-]+$/.test(occurrenceId) ||
        !occurrenceId.endsWith(`_${medicationId}`) ||
        (action !== "taken" && action !== "snoozed") ||
        !Number.isSafeInteger(scheduledAt) || !Number.isSafeInteger(createdAt) ||
        Math.abs(Date.now() - createdAt) > 24 * 60 * 60_000) {
      return reply({ error: "This medicine response is invalid." }, 400);
    }
    if (!await requireElderly(env, uid, token)) {
      return reply({ error: "This watch account is unavailable." }, 403);
    }
    const schedulePath = `medications/${uid}_${medicationId}`;
    const recordPath = `medication_records/${uid}_${occurrenceId}`;
    lockKey = `_watch-medication/${uid}/${occurrenceId}/lock`;
    const existing = await env.MEDICATION_IMAGES.head(lockKey);
    if (existing && existing.uploaded.getTime() > Date.now() - 90_000) {
      return reply({ error: "This response is already being saved." }, 429);
    }
    const lock = await env.MEDICATION_IMAGES.put(lockKey, "", {
      onlyIf: existing ? { etagMatches: existing.etag } : { etagDoesNotMatch: "*" },
    });
    if (!lock) return reply({ error: "This response is already being saved." }, 429);
    lockAcquired = true;
    for (let attempt = 0; attempt < 3; attempt++) {
      // Read after locking, and reread after a conflicting phone/watch write.
      const [schedule, previous] = await Promise.all([
        readDocument(env, schedulePath, token),
        readDocument(env, recordPath, token),
      ]);
      if (!schedule || schedule.fields?.active?.booleanValue === false) {
        return reply({ error: "This medicine schedule is no longer active." }, 409);
      }
      if (stringField(previous?.fields, "status") === "taken") {
        return reply({ saved: true, duplicate: true });
      }
      const scheduleFields = schedule.fields ?? {};
      const recordFields: Record<string, FirestoreValue> = {
      elderlyId: stringValue(uid),
      medicationId: stringValue(medicationId),
      recordKey: stringValue(occurrenceId),
      scheduledAt: { timestampValue: new Date(scheduledAt).toISOString() },
      status: stringValue(action),
      actionAt: { timestampValue: new Date(createdAt).toISOString() },
      snoozedUntil: action === "snoozed" && Number.isSafeInteger(remindAt)
        ? { timestampValue: new Date(remindAt).toISOString() }
        : { nullValue: null },
      watchActionId: stringValue(eventId),
      scheduleSnapshot: scheduleSnapshot(scheduleFields),
      updatedAt: { timestampValue: new Date().toISOString() },
      };
      const documentRoot = `projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
      const writes: ConditionalWrite[] = [{
        update: { name: `${documentRoot}/${recordPath}`, fields: recordFields },
        updateMask: { fieldPaths: Object.keys(recordFields) },
        currentDocument: documentVersion(previous),
      }];
      if (action === "taken" && scheduleFields.stockRemaining) {
        const remaining = Math.max(0, intField(scheduleFields, "stockRemaining"));
        const quantity = Math.max(1, Math.min(99, intField(scheduleFields, "quantity", 1)));
        writes.push({
          update: {
            name: `${documentRoot}/${schedulePath}`,
            fields: {
              stockRemaining: integerValue(Math.max(0, remaining - quantity)),
              updatedAt: { timestampValue: new Date().toISOString() },
            },
          },
          updateMask: { fieldPaths: ["stockRemaining", "updatedAt"] },
          currentDocument: documentVersion(schedule),
        });
      }
      // One atomic commit prevents Taken from surviving a failed stock write.
      // Version preconditions also cover concurrent actions from another client.
      try {
        if (!await commitMedicationWrites(env, token, writes)) continue;
      } catch (error) {
        if (error instanceof MedicationCommitError && error.status === 403) {
          // A stale deduction can fail the stock rule before its version check.
          // Retry only when rereading proves another client changed an input;
          // an unchanged permission denial must still fail closed.
          const [latestSchedule, latestRecord] = await Promise.all([
            readDocument(env, schedulePath, token),
            readDocument(env, recordPath, token),
          ]);
          if (latestSchedule?.updateTime !== schedule.updateTime ||
              latestRecord?.updateTime !== previous?.updateTime) continue;
        }
        throw error;
      }
      await env.MEDICATION_IMAGES.put(
        `_watch-medication/${uid}/${occurrenceId}/${eventId}`,
        JSON.stringify({ savedAt: new Date().toISOString(), action }),
      );
      return reply({ saved: true });
    }
    return reply({ error: "The medicine changed while saving. Please retry." }, 429);
  } catch (error) {
    console.error("Watch medication action failed", error);
    return reply({ error: "The medicine response will retry when online." }, 502);
  } finally {
    if (lockKey && lockAcquired) await env.MEDICATION_IMAGES.delete(lockKey);
  }
}
