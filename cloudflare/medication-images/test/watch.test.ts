import test from "node:test";
import assert from "node:assert/strict";
import {
  openWatchSession,
  saveWatchActivity,
  saveWatchMedicationAction,
  watchSnapshot,
} from "../src/watch.ts";

class Bucket {
  rows = new Map();
  async head(key) {
    const row = this.rows.get(key);
    return row ? { etag: key, uploaded: row.at } : null;
  }
  async put(key, value) {
    this.rows.set(key, { value, at: new Date() });
    return { etag: key };
  }
  async delete(key) { this.rows.delete(key); }
}

const env = {
  FIREBASE_PROJECT_ID: "watch-test",
  MEDICATION_IMAGES: new Bucket(),
};

test("elderly watch session enrolls its hardware key", async () => {
  const originalFetch = globalThis.fetch;
  let credentialWrite = null;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith("/users/elderly")) {
      return Response.json({ fields: {
        role: { stringValue: "elderly" },
        fullName: { stringValue: "George" },
      } });
    }
    if (value.endsWith("/elderly_profiles/elderly")) {
      return Response.json({ fields: { fullName: { stringValue: "George" } } });
    }
    if (value.includes("/watch_credentials/")) {
      credentialWrite = JSON.parse(options.body);
      return Response.json({ name: value });
    }
    throw new Error(`Unexpected request: ${value}`);
  };
  try {
    const response = await openWatchSession(new Request("https://test/v1/watch/session", {
      method: "POST",
      body: JSON.stringify({
        credentialId: "a".repeat(40),
        publicKey: "A".repeat(400),
      }),
    }), env, "elderly", "id-token");
    assert.equal(response.status, 200);
    assert.equal((await response.json()).name, "George");
    assert.equal(credentialWrite.fields.elderlyId.stringValue, "elderly");
    assert.equal(credentialWrite.fields.active.booleanValue, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("watch snapshot returns only today's active pending medicines", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith("/users/elderly")) {
      return Response.json({ fields: {
        role: { stringValue: "elderly" },
        fullName: { stringValue: "George" },
      } });
    }
    if (value.endsWith("/elderly_profiles/elderly")) {
      return Response.json({ fields: { fullName: { stringValue: "George" } } });
    }
    if (value.endsWith("/documents:runQuery")) {
      assert.equal(JSON.parse(options.body).structuredQuery.from[0].collectionId, "medications");
      return Response.json([
        { document: { fields: {
          elderlyId: { stringValue: "elderly" },
          scheduleKey: { stringValue: "morning-pill" },
          name: { stringValue: "Vitamin D" },
          dose: { stringValue: "500 mg" },
          quantity: { integerValue: "1" },
          visual: { stringValue: "tablet" },
          recurrence: { stringValue: "daily" },
          hour: { integerValue: "8" },
          minute: { integerValue: "30" },
          active: { booleanValue: true },
        } } },
        { document: { fields: {
          scheduleKey: { stringValue: "as-needed" },
          recurrence: { stringValue: "asNeeded" },
          active: { booleanValue: true },
        } } },
      ]);
    }
    if (value.includes("/medication_records/")) return new Response("", { status: 404 });
    throw new Error(`Unexpected request: ${value}`);
  };
  try {
    const response = await watchSnapshot(new Request("https://test/v1/watch/snapshot", {
      method: "POST",
      body: JSON.stringify({ date: "2026-09-28", offsetMinutes: 480 }),
    }), env, "elderly", "id-token");
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.medications.length, 1);
    assert.equal(result.medications[0].name, "Vitamin D");
    assert.equal(result.medications[0].occurrenceId, "2026-09-28_morning-pill");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("watch activity updates only the signed-in elderly status", async () => {
  const originalFetch = globalThis.fetch;
  let update = null;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith("/users/elderly")) {
      return Response.json({ fields: { role: { stringValue: "elderly" } } });
    }
    if (value.includes("/activity_status/elderly")) {
      update = JSON.parse(options.body);
      return Response.json({ name: value });
    }
    throw new Error(`Unexpected request: ${value}`);
  };
  try {
    const response = await saveWatchActivity(new Request("https://test/v1/watch/activity", {
      method: "POST",
      body: JSON.stringify({
        label: "Walking",
        confidence: 0.9,
        fallProbability: 0.02,
        possibleFall: false,
        updatedAt: Date.now(),
      }),
    }), env, "elderly", "id-token");
    assert.equal(response.status, 200);
    assert.equal(update.fields.watch.mapValue.fields.label.stringValue, "Walking");
    assert.equal(update.fields.watch.mapValue.fields.active.booleanValue, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("watch taken action saves the dose and decrements stock once", async () => {
  const originalFetch = globalThis.fetch;
  let recordWrite = null;
  let stockWrite = null;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith('/documents:commit')) {
      const { writes } = JSON.parse(options.body);
      assert.equal(writes.length, 2);
      const record = writes.find(write => write.update.name.includes('/medication_records/'));
      const stock = writes.find(write => write.update.name.includes('/medications/'));
      assert.deepEqual(record.currentDocument, { exists: false });
      assert.deepEqual(stock.currentDocument, { updateTime: '2026-09-28T00:00:00.000000Z' });
      recordWrite = record.update;
      stockWrite = stock.update;
      return Response.json({ writeResults: [{}, {}] });
    }
    if (value.endsWith("/users/elderly")) {
      return Response.json({ fields: { role: { stringValue: "elderly" } } });
    }
    if (value.includes("/medications/elderly_morning-pill")) {
      if (options.method === "PATCH") {
        stockWrite = JSON.parse(options.body);
        return Response.json({ name: value });
      }
      return Response.json({ updateTime: '2026-09-28T00:00:00.000000Z', fields: {
        active: { booleanValue: true },
        name: { stringValue: "Vitamin D" },
        quantity: { integerValue: "2" },
        stockRemaining: { integerValue: "10" },
      } });
    }
    if (value.includes("/medication_records/elderly_2026-09-28_morning-pill")) {
      if (options.method === "PATCH") {
        recordWrite = JSON.parse(options.body);
        return Response.json({ name: value });
      }
      return new Response("", { status: 404 });
    }
    throw new Error(`Unexpected request: ${value}`);
  };
  try {
    const now = Date.now();
    const response = await saveWatchMedicationAction(new Request("https://test/v1/watch/medication-action", {
      method: "POST",
      body: JSON.stringify({
        eventId: "dose-action-1",
        medicationId: "morning-pill",
        occurrenceId: "2026-09-28_morning-pill",
        action: "taken",
        scheduledAt: now - 60_000,
        createdAt: now,
        remindAt: now - 60_000,
      }),
    }), env, "elderly", "id-token");
    assert.equal(response.status, 200);
    assert.equal(recordWrite.fields.status.stringValue, "taken");
    assert.equal(stockWrite.fields.stockRemaining.integerValue, "8");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

async function medicationFixture(run, { rejectOnce = false, conflictOnce = false, permissionConflictOnce = false, denied = false, alreadyTaken = false } = {}) {
  const originalFetch = globalThis.fetch;
  let stock = alreadyTaken ? 8 : 10;
  let saved = alreadyTaken ? { status: { stringValue: 'taken' } } : null;
  let version = '2026-10-28T00:00:00.000000Z';
  let commits = 0;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith('/users/elderly')) return Response.json({ fields: { role: { stringValue: 'elderly' } } });
    if (value.endsWith('/medications/elderly_morning-pill')) return Response.json({
      updateTime: version,
      fields: { active: { booleanValue: true }, name: { stringValue: 'TEST ONLY' }, quantity: { integerValue: '2' }, stockRemaining: { integerValue: String(stock) } },
    });
    if (value.includes('/medication_records/')) return saved
      ? Response.json({ updateTime: version, fields: saved })
      : new Response('', { status: 404 });
    if (value.endsWith('/documents:commit')) {
      commits++;
      if (rejectOnce) { rejectOnce = false; return new Response('', { status: 503 }); }
      if (denied) return Response.json({ error: { status: 'PERMISSION_DENIED' } }, { status: 403 });
      if (permissionConflictOnce) {
        permissionConflictOnce = false; stock = 6; version = '2026-10-28T00:00:01.000000Z';
        return Response.json({ error: { status: 'PERMISSION_DENIED' } }, { status: 403 });
      }
      if (conflictOnce) {
        conflictOnce = false; stock = 6; version = '2026-10-28T00:00:01.000000Z';
        return Response.json({ error: { status: 'FAILED_PRECONDITION' } }, { status: 400 });
      }
      const { writes } = JSON.parse(options.body);
      const record = writes.find(write => write.update.name.includes('/medication_records/'));
      const schedule = writes.find(write => write.update.name.includes('/medications/'));
      assert.deepEqual(schedule.currentDocument, { updateTime: version });
      assert.deepEqual(record.currentDocument, { exists: false });
      // Apply the mocked commit as one unit, never as two partial PATCH calls.
      saved = record.update.fields;
      stock = Number(schedule.update.fields.stockRemaining.integerValue);
      return Response.json({ writeResults: [{}, {}] });
    }
    throw new Error(`Unexpected request: ${value}`);
  };
  const request = async eventId => {
    const now = Date.now();
    const response = await saveWatchMedicationAction(new Request('https://test/v1/watch/medication-action', {
      method: 'POST', body: JSON.stringify({ eventId, medicationId: 'morning-pill', occurrenceId: '2026-10-28_morning-pill', action: 'taken', scheduledAt: now - 60000, createdAt: now, remindAt: now - 60000 }),
    }), { FIREBASE_PROJECT_ID: 'watch-test', MEDICATION_IMAGES: new Bucket() }, 'elderly', 'id-token');
    return { status: response.status, body: await response.json() };
  };
  try { await run({ request, state: () => ({ stock, saved, commits }) }); }
  finally { globalThis.fetch = originalFetch; }
}

test('rejected atomic medication commit leaves stock and outcome unchanged, then retry saves once', async () => {
  await medicationFixture(async ({ request, state }) => {
    assert.equal((await request('first')).status, 502);
    assert.equal(state().saved, null);
    assert.equal(state().stock, 10);
    assert.equal((await request('retry')).status, 200);
    assert.equal(state().stock, 8);
    assert.equal(state().saved.status.stringValue, 'taken');
    assert.equal((await request('different-client')).body.duplicate, true);
    assert.equal(state().stock, 8);
    assert.equal(state().commits, 2);
  }, { rejectOnce: true });
});

test('conflicting medication version rereads current stock before retrying', async () => {
  await medicationFixture(async ({ request, state }) => {
    assert.equal((await request('conflict')).status, 200);
    assert.equal(state().stock, 4);
    assert.equal(state().commits, 2);
  }, { conflictOnce: true });
});

test('previously Taken occurrence never starts another stock commit', async () => {
  await medicationFixture(async ({ request, state }) => {
    assert.equal((await request('duplicate')).body.duplicate, true);
    assert.equal(state().stock, 8);
    assert.equal(state().commits, 0);
  }, { alreadyTaken: true });
});

test('stale stock-rule rejection retries only after a changed document version', async () => {
  await medicationFixture(async ({ request, state }) => {
    assert.equal((await request('stale-rule')).status, 200);
    assert.equal(state().stock, 4);
    assert.equal(state().commits, 2);
  }, { permissionConflictOnce: true });
});

test('unchanged permission denial fails without saving or repeated commits', async () => {
  await medicationFixture(async ({ request, state }) => {
    assert.equal((await request('denied')).status, 502);
    assert.equal(state().saved, null);
    assert.equal(state().stock, 10);
    assert.equal(state().commits, 1);
  }, { denied: true });
});
