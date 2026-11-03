import test from "node:test";
import assert from "node:assert/strict";
import { generateStatisticsForecast } from "../src/statistics.ts";

class Bucket {
  rows = new Map<string, { value: string; at: Date }>();

  async get(key: string) {
    const row = this.rows.get(key);
    return row
      ? { uploaded: row.at, json: async () => JSON.parse(row.value) }
      : null;
  }

  async put(key: string, value: string) {
    this.rows.set(key, { value, at: new Date() });
    return { etag: key };
  }
}

function request() {
  return new Request("https://test/v1/statistics/forecast", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      elderlyId: "elderly-account-123",
      periodDays: 7,
      asOf: "2026-10-11T10:00:00.000Z",
      totals: {
        taken: 5,
        missed: 1,
        unresolved: 1,
        doses: 7,
        possibleFallAlerts: 1,
        recordDays: 7,
      },
      days: Array.from({ length: 7 }, (_, index) => ({
        date: `2026-10-${String(index + 5).padStart(2, "0")}`,
        taken: index < 5 ? 1 : 0,
        missed: index === 5 ? 1 : 0,
        unresolved: index === 6 ? 1 : 0,
        possibleFallAlerts: index === 4 ? 1 : 0,
      })),
      alertHours: [0, 1, 0, 0],
      fallStatuses: { "Alert sent": 1, "Cancelled": 0, "Unresolved": 0 },
    }),
  });
}

test("Groq receives anonymous aggregates and identical requests use cache", async () => {
  const bucket = new Bucket();
  const env = {
    FIREBASE_PROJECT_ID: "test",
    MEDICATION_IMAGES: bucket,
    GROQ_API_KEY: "test-key",
    GROQ_MODEL: "openai/gpt-oss-20b",
  };
  const originalFetch = globalThis.fetch;
  let groqCalls = 0;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.includes("/care_links/caregiver_elderly-account-123")) {
      return Response.json({ fields: {
        caregiverId: { stringValue: "caregiver" },
        elderlyId: { stringValue: "elderly-account-123" },
        status: { stringValue: "active" },
      } });
    }
    if (value.includes("api.groq.com/openai/v1/chat/completions")) {
      groqCalls++;
      const body = JSON.parse(options.body as string);
      const prompt = body.messages[1].content as string;
      assert.doesNotMatch(prompt, /elderly-account-123/);
      assert.doesNotMatch(prompt, /elderlyId/);
      assert.match(prompt, /possibleFallAlerts/);
      assert.equal(options.headers?.authorization, "Bearer test-key");
      assert.equal(body.model, "openai/gpt-oss-20b");
      assert.equal(body.response_format.json_schema.strict, true);
      return Response.json({ choices: [{ message: {
        content: JSON.stringify({
          summary: "The recorded routine is likely to remain mostly stable.",
          predictedCompletion: 76,
          completionLower: 58,
          completionUpper: 89,
          trend: "stable",
          possibleFallAlertLevel: "moderate",
          actions: ["Review unresolved dose records."],
          limitations: "Only seven days of saved records were supplied.",
        }),
      } }] });
    }
    throw new Error(`Unexpected outbound request: ${value}`);
  };
  try {
    const first = await generateStatisticsForecast(
      request(),
      env as never,
      "caregiver",
      "firebase-token",
    );
    assert.equal(first.status, 200);
    assert.equal((await first.json()).forecast.predictedCompletion, 76);
    const second = await generateStatisticsForecast(
      request(),
      env as never,
      "caregiver",
      "firebase-token",
    );
    assert.equal((await second.json()).cached, true);
    assert.equal(groqCalls, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("missing Groq secret and an unlinked caregiver fail safely", async () => {
  const bucket = new Bucket();
  const missing = await generateStatisticsForecast(
    request(),
    { FIREBASE_PROJECT_ID: "test", MEDICATION_IMAGES: bucket } as never,
    "caregiver",
    "firebase-token",
  );
  assert.equal(missing.status, 503);

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("", { status: 404 });
  try {
    const denied = await generateStatisticsForecast(
      request(),
      {
        FIREBASE_PROJECT_ID: "test",
        MEDICATION_IMAGES: bucket,
        GROQ_API_KEY: "test-key",
      } as never,
      "caregiver",
      "firebase-token",
    );
    assert.equal(denied.status, 403);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
