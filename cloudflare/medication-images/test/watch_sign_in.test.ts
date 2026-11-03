import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { importSPKI, jwtVerify } from "jose";
import { issueWatchSignInToken } from "../src/watch_sign_in.ts";

const keys = generateKeyPairSync("rsa", { modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
const env = { FIREBASE_PROJECT_ID: "test", FIREBASE_SERVICE_ACCOUNT: JSON.stringify({
  project_id: "test", client_email: "watch@test.iam.gserviceaccount.com", private_key: keys.privateKey,
}) };
const request = (value = {}) => new Request("https://test/v1/watch/sign-in-token", {
  method: "POST", body: JSON.stringify({ nonce: "a".repeat(64), ...value }),
});

test("phone can only mint its own short-lived session, regardless of supplied account ID", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.ok(String(url).endsWith("/users/elderly-owner"));
    assert.equal(options.headers.authorization, "Bearer signed-in-token");
    return Response.json({ fields: { role: { stringValue: "elderly" } } });
  };
  try {
    const response = await issueWatchSignInToken(request({ uid: "another-user" }), env, "elderly-owner", "signed-in-token");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const value = await response.json();
    const { payload } = await jwtVerify(value.customToken, await importSPKI(keys.publicKey, "RS256"), {
      audience: "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
      issuer: "watch@test.iam.gserviceaccount.com",
    });
    assert.equal(payload.uid, "elderly-owner");
    assert.ok(payload.exp - payload.iat <= 300);
    assert.equal(value.nonce, "a".repeat(64));
  } finally { globalThis.fetch = original; }
});

for (const scenario of ["caregiver", "missing-profile", "missing-secret", "bad-nonce"]) {
  test(`phone sign-in refuses ${scenario}`, async () => {
    const original = globalThis.fetch;
    let reads = 0;
    globalThis.fetch = async () => {
      reads++;
      return scenario === "missing-profile" ? new Response("", { status: 403 })
        : Response.json({ fields: { role: { stringValue: scenario === "caregiver" ? "caregiver" : "elderly" } } });
    };
    try {
      const response = await issueWatchSignInToken(request(scenario === "bad-nonce" ? { nonce: "123456" } : {}),
        scenario === "missing-secret" ? { FIREBASE_PROJECT_ID: "test" } : env, "elderly", "token");
      assert.equal(response.status, scenario === "bad-nonce" ? 400 : scenario === "caregiver" ? 403 : 503);
      assert.equal((await response.json()).customToken, undefined);
      if (scenario === "bad-nonce") assert.equal(reads, 0);
    } finally { globalThis.fetch = original; }
  });
}
