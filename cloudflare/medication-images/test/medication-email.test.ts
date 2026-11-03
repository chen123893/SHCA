import test from "node:test";
import assert from "node:assert/strict";
import { sendMedicationReminderEmail } from "../src/index.ts";

class Bucket {
  rows = new Map<string, string>();
  async head(key: string) {
    return this.rows.has(key) ? { etag: key, uploaded: new Date() } : null;
  }
  async put(key: string, value: string) {
    this.rows.set(key, value);
    return { etag: key };
  }
}

const reminder = () => new Request(
  "https://test/v1/medication-reminders/email",
  {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      elderlyId: "elderly",
      medicationId: "medication",
      occurrenceDate: "2026-09-28",
    }),
  },
);

test("snoozed medication sends no email; missed medication sends once", async () => {
  const bucket = new Bucket();
  const env = {
    FIREBASE_PROJECT_ID: "test",
    MEDICATION_IMAGES: bucket,
    BREVO_API_KEY: "brevo-test",
    BREVO_SENDER_EMAIL: "alerts@shca.test",
  };
  const originalFetch = globalThis.fetch;
  let status = "snoozed";
  let emails = 0;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.endsWith("/medications/elderly_medication")) {
      return Response.json({ fields: {
        elderlyId: { stringValue: "elderly" },
        name: { stringValue: "Vitamin D" },
        instruction: { stringValue: "After food" },
        hour: { integerValue: "8" },
        minute: { integerValue: "0" },
      } });
    }
    if (value.endsWith("/medication_records/elderly_2026-09-28_medication")) {
      return Response.json({ fields: {
        elderlyId: { stringValue: "elderly" },
        medicationId: { stringValue: "medication" },
        status: { stringValue: status },
      } });
    }
    if (value.endsWith(":runQuery")) {
      return Response.json([{ document: { fields: {
        caregiverId: { stringValue: "caregiver" },
        caregiverEmail: { stringValue: "caregiver@example.com" },
        medicationEmailAlertsEnabled: { booleanValue: true },
        status: { stringValue: "active" },
      } } }]);
    }
    if (value.endsWith("/elderly_profiles/elderly")) {
      return Response.json({ fields: { fullName: { stringValue: "George" } } });
    }
    if (value.includes("api.brevo.com")) {
      emails++;
      const message = JSON.parse(options.body as string);
      assert.match(message.subject, /missed medication/i);
      assert.deepEqual(message.tags, ["medication-missed"]);
      return Response.json({ messageId: "missed-email" });
    }
    throw new Error(`Unexpected outbound request: ${value}`);
  };
  try {
    await assert.rejects(
      () => sendMedicationReminderEmail(
        reminder(),
        env as never,
        "elderly",
        "id-token",
      ),
      (error: unknown) =>
        error instanceof Error &&
        (error as Error & { status?: number }).status === 409,
    );
    assert.equal(emails, 0);

    status = "missed";
    const missed = await sendMedicationReminderEmail(
      reminder(),
      env as never,
      "elderly",
      "id-token",
    );
    assert.deepEqual(await missed.json(), {
      sent: 1,
      alreadySent: 0,
      unavailable: 0,
      linkedCaregivers: 1,
      missingEmail: 0,
      disabled: 0,
    });
    assert.equal(emails, 1);

    const retry = await sendMedicationReminderEmail(
      reminder(),
      env as never,
      "elderly",
      "id-token",
    );
    assert.equal((await retry.json()).alreadySent, 1);
    assert.equal(emails, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
