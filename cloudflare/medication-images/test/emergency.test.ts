import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { sendEmergencyPush, sendWatchEmergency } from "../src/emergency.ts";

class Bucket {
  rows = new Map();
  async head(key) { const row = this.rows.get(key); return row ? { etag: key, uploaded: row.at } : null; }
  async get(key) { const row = this.rows.get(key); return row ? { json: async () => JSON.parse(row.value) } : null; }
  async put(key, value, options) {
    if (options?.onlyIf?.etagDoesNotMatch === "*" && this.rows.has(key)) return null;
    this.rows.set(key, { value, at: new Date() }); return { etag: key };
  }
  async delete(key) { this.rows.delete(key); }
}
const body = () => new Request("https://test/v1/emergency-alerts/push", {method:"POST",
  body:JSON.stringify({alertId:"test_alert"}),headers:{"content-type":"application/json"}});
test("missing sender configuration is explicit", async () => {
  const response = await sendEmergencyPush(body(), {FIREBASE_PROJECT_ID:"test", MEDICATION_IMAGES:new Bucket()}, "elderly", "id-token");
  assert.equal(response.status,503);
  assert.match((await response.json()).error, /not configured/);
});

for (const source of ["wearable_fall", "wearable_sos"]) {
for (const withLocation of [false, true]) {
for (const phoneState of ["none", "located", "missing"]) {
const phoneFirst = phoneState !== "none";
const phoneLocated = phoneState === "located";
test(`hardware-signed ${source} ${withLocation ? "with location" : "legacy"} ${phoneState} sends push and email without the phone`, async () => {
  const keys = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const serviceKey = keys.privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const publicKey = keys.publicKey.export({ type: "spki", format: "der" }).toString("base64");
  const credentialId = "a".repeat(40);
  const eventId = "watch-event-1";
  const createdAt = Date.now();
  const probabilityPpm = 920000;
  const location = { latitude: 3.139, longitude: 101.6869, recordedAt: createdAt - 600000,
    accuracyMeters: 30, source: "watch", kind: "last_known" };
  const locationJson = withLocation ? JSON.stringify(location) : undefined;
  const canonical = [credentialId, eventId, String(createdAt), source, String(probabilityPpm)].join("\n") +
    (locationJson ? "\n" + locationJson : "");
  const signature = sign("sha256", Buffer.from(canonical), keys.privateKey).toString("base64");
  const request = (value = signature, json = locationJson) => new Request("https://test/v1/watch-emergency", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ credentialId, eventId, createdAt, source, probabilityPpm, fallProbabilityPpm: probabilityPpm, signature: value, ...(json ? { locationJson: json } : {}) }),
  });
  const env = { FIREBASE_PROJECT_ID: "watch-test", FIREBASE_WEB_API_KEY: "test-api-key", MEDICATION_IMAGES: new Bucket(),
    BREVO_API_KEY: "brevo-test", BREVO_SENDER_EMAIL: "alerts@shca.test",
    FIREBASE_SERVICE_ACCOUNT: JSON.stringify({ project_id: "watch-test", client_email: "watch@test.iam.gserviceaccount.com", private_key: serviceKey }) };
  const originalFetch = globalThis.fetch;
  const writes = [];
  let sends = 0;
  let emails = 0;
  globalThis.fetch = async (url, options = {}) => {
    const value = String(url);
    if (value.includes("oauth2.googleapis.com")) return Response.json({ access_token: "watch-admin-token", expires_in: 3600 });
    if (value.includes("identitytoolkit.googleapis.com")) return Response.json({ idToken: "elderly-user-token" });
    if (value.endsWith(`/watch_credentials/${credentialId}`)) return Response.json({ fields: {
      elderlyId: { stringValue: "elderly" }, publicKey: { stringValue: publicKey },
      algorithm: { stringValue: "RS256" }, active: { booleanValue: true },
    } });
    if (value.endsWith("/users/elderly")) return Response.json({ fields: { role: { stringValue: "elderly" }, fullName: { stringValue: "George" } } });
    if (value.endsWith("/elderly_profiles/elderly")) return Response.json({ fields: { fullName: { stringValue: "George" } } });
    if (value.endsWith(":runQuery")) return Response.json([{ document: { fields: {
      caregiverId: { stringValue: "caregiver" }, caregiverEmail: { stringValue: "caregiver@example.com" }, status: { stringValue: "active" },
    } } }]);
    if (value.endsWith("/emergency_alerts/watch_elderly_watch-event-1")) return Response.json({ fields: {
      elderlyId: { stringValue: "elderly" }, watchEventId: { stringValue: eventId }, status: { stringValue: "active" },
      createdAt: { timestampValue: new Date(createdAt).toISOString() },
      ...(phoneLocated ? { location: { mapValue: { fields: {
        latitude: { doubleValue: 3.14 }, longitude: { doubleValue: 101.68 },
        recordedAt: { integerValue: String(createdAt - 600000) }, accuracyMeters: { doubleValue: 75 },
        source: { stringValue: "phone" }, kind: { stringValue: "last_known" },
      } } } } : {}),
    } });
    if (options.method === "PATCH") {
      if (value.includes("/emergency_alerts/")) {
        const saved = JSON.parse(options.body).fields.location;
        if (withLocation) {
          assert.equal(saved.mapValue.fields.latitude.doubleValue, location.latitude);
          assert.equal(saved.mapValue.fields.recordedAt.doubleValue, location.recordedAt);
        } else assert.equal(saved, undefined);
      }
      writes.push(value); return Response.json({ name: value }, {status: phoneFirst && value.includes("/emergency_alerts/") && value.includes("exists=false") ? 409 : 200});
    }
    if (value.endsWith("/caregiver_profiles/caregiver")) return Response.json({ fields: {} });
    if (value.includes("/caregiver_profiles/caregiver/push_tokens")) return Response.json({ documents: [{
      name: "test/push_tokens/watch-device", fields: { userId: { stringValue: "caregiver" }, token: { stringValue: "caregiver-token" } },
    }] });
    if (value.includes("fcm.googleapis.com")) {
      sends++;
      const data = JSON.parse(options.body).message.data;
      if (phoneLocated || withLocation) {
        assert.match(data.mapsUrl, phoneLocated ? /3.14,101.68/ : /3.139,101.6869/);
        assert.equal(data.locationSource, phoneLocated ? "phone" : "watch");
        assert.equal(data.locationKind, "last_known");
      } else assert.equal(data.mapsUrl, undefined);
      return Response.json({ name: "accepted" });
    }
    if (value.includes("api.brevo.com")) {
      emails++;
      const message = JSON.parse(options.body);
      assert.match(message.subject, source === "wearable_fall" ? /possible fall/i : /SOS help requested/i);
      assert.deepEqual(message.tags, [source === "wearable_fall" ? "fall-alert" : "sos-alert"]);
      if (phoneLocated || withLocation) {
        assert.match(message.textContent, phoneLocated ? /Last known location from the phone/ : /Last known location from the watch/);
        assert.match(message.textContent, phoneLocated ? /3.14,101.68/ : /3.139,101.6869/);
        assert.match(message.htmlContent, /Open location in Maps/);
      } else assert.match(message.textContent, /Location unavailable/);
      return Response.json({ messageId: "fall-email" });
    }
    throw new Error("Unexpected outbound request: " + value);
  };
  try {
    const denied = await sendWatchEmergency(request(signature.slice(1)), env);
    assert.equal(denied.status, 401);
    assert.equal(writes.length, 0);
    if (withLocation) {
      const tampered = await sendWatchEmergency(request(signature, JSON.stringify({ ...location, longitude: 102 })), env);
      assert.equal(tampered.status, 401);
      const invalid = await sendWatchEmergency(request(signature, JSON.stringify({ ...location, latitude: 91 })), env);
      assert.equal(invalid.status, 400);
      assert.equal(writes.length, 0);
      assert.equal(sends, 0);
      assert.equal(emails, 0);
    }
    const response = await sendWatchEmergency(request(), env);
    const result = await response.json();
    assert.equal(result.accepted, 1);
    assert.equal(sends, 1);
    assert.equal(emails, 1);
    assert.equal(result.emailAccepted, 1);
    assert.equal(writes.length, (source === "wearable_fall" ? 2 : 1) + (phoneState === "missing" && withLocation ? 1 : 0));
    assert.ok(writes.some(value => value.includes("/emergency_alerts/watch_elderly_watch-event-1")));
    assert.equal(writes.some(value => value.includes("/fall_events/watch_elderly_watch-event-1")), source === "wearable_fall");
  } finally { globalThis.fetch = originalFetch; }
});
}
}
}
test("sender verifies ownership, links and returns acceptance without duplicate sending", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength:2048,
    privateKeyEncoding:{type:"pkcs8",format:"pem"}, publicKeyEncoding:{type:"spki",format:"pem"} });
  const env = {FIREBASE_PROJECT_ID:"test",MEDICATION_IMAGES:new Bucket(),
    BREVO_API_KEY:"brevo-test",BREVO_SENDER_EMAIL:"alerts@shca.test",
    FIREBASE_SERVICE_ACCOUNT:JSON.stringify({project_id:"test",client_email:"test@test.iam.gserviceaccount.com",private_key:privateKey})};
  const originalFetch = globalThis.fetch;
  let sends = 0;
  let emails = 0;
  let owner = "different-user";
  let fcmStatus = 200;
  const phoneLocation = { mapValue: { fields: {
    latitude: { doubleValue: 3.14 }, longitude: { doubleValue: 101.68 },
    recordedAt: { integerValue: String(Date.now() - 600000) }, accuracyMeters: { doubleValue: 75 },
    source: { stringValue: "phone" }, kind: { stringValue: "last_known" },
  } } };
  globalThis.fetch = async (url, options) => {
    const value = String(url);
    if (value.endsWith("/emergency_alerts/test_alert")) return Response.json({fields:{elderlyId:{stringValue:owner},
      elderlyName:{stringValue:"George"},type:{stringValue:"possible_fall"},location:phoneLocation,
      createdAt:{timestampValue:new Date().toISOString()}}});
    if (value.endsWith("/users/elderly")) return Response.json({fields:{role:{stringValue:"elderly"}}});
    if (value.includes("oauth2.googleapis.com")) return Response.json({access_token:"fake-admin-token",expires_in:3600});
    if (value.endsWith(":runQuery")) return Response.json([
      {document:{fields:{caregiverId:{stringValue:"caregiver"},caregiverEmail:{stringValue:"caregiver@example.com"},status:{stringValue:"active"}}}},
      {document:{fields:{caregiverId:{stringValue:"removed"},status:{stringValue:"removed"}}}},
    ]);
    if (value.endsWith("/caregiver_profiles/caregiver")) return Response.json({fields:{
      alertPreferences:{mapValue:{fields:{pushAlert:{booleanValue:true}}}}}});
    if (value.includes("/caregiver_profiles/caregiver/push_tokens")) return Response.json({documents:[{
      name:"test/push_tokens/device", fields:{userId:{stringValue:"caregiver"},token:{stringValue:"fake-device-token"}}}]});
    if (value.includes("fcm.googleapis.com")) {
      sends++;
      const message = JSON.parse(options.body).message;
      assert.equal(message.token,"fake-device-token");
      assert.equal(message.data.alertId,"test_alert");
      assert.match(message.data.mapsUrl, /3.14,101.68/);
      assert.equal(message.data.locationKind, "last_known");
      return Response.json(
        fcmStatus === 200
          ? {name:"projects/test/messages/fake-accepted"}
          : {error:{status:"PERMISSION_DENIED"}},
        {status:fcmStatus},
      );
    }
    if (value.includes("api.brevo.com")) {
      emails++;
      const message = JSON.parse(options.body);
      assert.match(message.subject,/possible fall/i);
      return Response.json({messageId:"fall-email"});
    }
    throw new Error("Unexpected outbound request: " + value);
  };
  try {
    const denied = await sendEmergencyPush(body(),env,"elderly","id-token");
    assert.equal(denied.status,403); assert.equal(sends,0);
    owner = "elderly";
    fcmStatus = 403;
    const credentialFailure = await sendEmergencyPush(body(),env,"elderly","id-token");
    assert.equal(credentialFailure.status,503); assert.equal(sends,1);
    assert.match((await credentialFailure.json()).error,/authorization/);
    fcmStatus = 200;
    const accepted = await sendEmergencyPush(body(),env,"elderly","id-token");
    assert.equal((await accepted.json()).accepted,1); assert.equal(sends,2);
    const retry = await sendEmergencyPush(body(),env,"elderly","id-token");
    assert.equal((await retry.json()).accepted,1); assert.equal(sends,2);
    assert.equal(emails,1);
  } finally { globalThis.fetch = originalFetch; }
});

for (const scenario of ["no_device", "disabled", "rejected", "push_network", "email_failure", "no_link"]) {
  test(`phone SOS reports ${scenario} and attempts the other channel independently`, async () => {
    const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048,
      privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
    const env = { FIREBASE_PROJECT_ID: "sos-test", MEDICATION_IMAGES: new Bucket(),
      BREVO_API_KEY: "test", BREVO_SENDER_EMAIL: "alerts@shca.test",
      FIREBASE_SERVICE_ACCOUNT: JSON.stringify({ project_id: "sos-test", client_email: "sos@test.iam.gserviceaccount.com", private_key: privateKey }) };
    const originalFetch = globalThis.fetch;
    let emails = 0, pushes = 0;
    globalThis.fetch = async (url, options = {}) => {
      const value = String(url);
      if (value.endsWith("/emergency_alerts/test_alert")) return Response.json({ fields: {
        elderlyId: { stringValue: "elderly" }, elderlyName: { stringValue: "<George>" },
        type: { stringValue: "manual_sos" }, createdAt: { timestampValue: new Date().toISOString() },
      } });
      if (value.endsWith("/users/elderly")) return Response.json({ fields: { role: { stringValue: "elderly" } } });
      if (value.includes("oauth2.googleapis.com")) return Response.json({ access_token: "sos-token", expires_in: 3600 });
      if (value.endsWith(":runQuery")) return Response.json(scenario === "no_link" ? [] : [{ document: { fields: {
        caregiverId: { stringValue: "caregiver" }, caregiverEmail: { stringValue: "caregiver@example.com" }, status: { stringValue: "active" },
      } } }]);
      if (value.endsWith("/caregiver_profiles/caregiver")) return Response.json({ fields: {
        alertPreferences: { mapValue: { fields: { pushAlert: { booleanValue: scenario !== "disabled" } } } },
      } });
      if (value.includes("/push_tokens")) return Response.json({ documents: scenario === "no_device" ? [] : [{
        name: "test/push_tokens/device", fields: { userId: { stringValue: "caregiver" }, token: { stringValue: "token" } },
      }] });
      if (value.includes("fcm.googleapis.com")) {
        pushes++;
        if (scenario === "push_network") throw new Error("network unavailable");
        return Response.json(scenario === "rejected" ? { error: { status: "NOT_FOUND" } } : { name: "accepted" }, { status: scenario === "rejected" ? 404 : 200 });
      }
      if (value.includes("api.brevo.com")) {
        emails++;
        const message = JSON.parse(options.body);
        assert.match(message.subject, /SOS help requested/);
        assert.deepEqual(message.tags, ["sos-alert"]);
        assert.ok(message.htmlContent.includes("&lt;George&gt;"));
        return Response.json({ messageId: "email" }, { status: scenario === "email_failure" ? 503 : 200 });
      }
      throw new Error("Unexpected request: " + value);
    };
    try {
      const response = await sendEmergencyPush(body(), env, "elderly", "user-token");
      const result = await response.json();
      assert.equal(result.accepted, scenario === "email_failure" ? 1 : 0);
      assert.equal(result.emailAccepted, ["email_failure", "no_link"].includes(scenario) ? 0 : 1);
      assert.equal(emails, scenario === "no_link" ? 0 : 1);
      if (scenario === "no_device") { assert.match(result.error, /No caregiver phone is registered/); assert.equal(result.unavailable, 1); }
      if (scenario === "disabled") { assert.match(result.error, /switched off/); assert.equal(pushes, 0); }
      if (scenario === "rejected") assert.match(result.error, /device token/);
      if (scenario === "push_network") assert.equal(response.status, 502);
      if (scenario === "email_failure") assert.equal(result.emailUnavailable, 1);
      if (scenario === "no_link") assert.match(result.error, /No active caregiver/);
    } finally { globalThis.fetch = originalFetch; }
  });
}
