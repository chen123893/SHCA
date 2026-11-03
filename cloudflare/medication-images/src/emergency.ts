import { importPKCS8, SignJWT } from "jose";

export interface EmergencyEnv {
  FIREBASE_PROJECT_ID: string;
  FIREBASE_WEB_API_KEY?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  BREVO_API_KEY?: string;
  BREVO_SENDER_EMAIL?: string;
  BREVO_SENDER_NAME?: string;
  MEDICATION_IMAGES: R2Bucket;
}

async function firebaseUserToken(env: EmergencyEnv, uid: string): Promise<string> {
  const service = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT ?? "{}");
  if (!env.FIREBASE_WEB_API_KEY || !service.client_email || !service.private_key) {
    throw new Error("watch-user-token-unavailable");
  }
  const key = await importPKCS8(service.private_key, "RS256");
  const customToken = await new SignJWT({ uid })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(service.client_email)
    .setSubject(service.client_email)
    .setAudience("https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit")
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);
  const response = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${encodeURIComponent(env.FIREBASE_WEB_API_KEY)}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: customToken, returnSecureToken: true }),
    },
  );
  const value = await response.json() as { idToken?: string };
  if (!response.ok || !value.idToken) throw new Error("watch-user-token-unavailable");
  return value.idToken;
}
type Doc = { fields?: Record<string, any>; name?: string };
type CareLinkRow = { document?: Doc };
type CaregiverRecipient = { id: string; email: string };
let accessToken: { value: string; expires: number; email: string } | undefined;

const reply = (value: unknown, status = 200) => Response.json(value, {
  status,
  headers: { "cache-control": "no-store" },
});

async function googleToken(env: EmergencyEnv): Promise<string> {
  const service = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT ?? "{}");
  if (!service.client_email || !service.private_key || service.project_id !== env.FIREBASE_PROJECT_ID) {
    throw new Error("invalid-service-account");
  }
  if (accessToken && accessToken.email === service.client_email && accessToken.expires > Date.now() + 60000) return accessToken.value;
  const key = await importPKCS8(service.private_key, "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging https://www.googleapis.com/auth/datastore" })
    .setProtectedHeader({ alg: "RS256" }).setIssuer(service.client_email)
    .setAudience("https://oauth2.googleapis.com/token").setIssuedAt().setExpirationTime("1h").sign(key);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  const value = await response.json() as { access_token?: string; expires_in?: number };
  if (!response.ok || !value.access_token) throw new Error("oauth-unavailable");
  accessToken = { value: value.access_token, expires: Date.now() + (value.expires_in ?? 3600) * 1000, email: service.client_email };
  return value.access_token;
}

function base(env: EmergencyEnv): string {
  return `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
}

async function read(env: EmergencyEnv, path: string, token: string): Promise<Doc | null> {
  const response = await fetch(`${base(env)}/${path}`, { headers: { authorization: `Bearer ${token}` } });
  return response.ok ? await response.json() as Doc : null;
}

async function caregiverRecipients(
  env: EmergencyEnv,
  uid: string,
  token: string,
): Promise<CaregiverRecipient[]> {
  const response = await fetch(`${base(env)}:runQuery`, {
    method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ structuredQuery: { from: [{ collectionId: "care_links" }], where: { fieldFilter: {
      field: { fieldPath: "elderlyId" }, op: "EQUAL", value: { stringValue: uid },
    } } } }),
  });
  if (!response.ok) throw new Error("care-links-unavailable");
  const rows = await response.json() as CareLinkRow[];
  const recipients = new Map<string, CaregiverRecipient>();
  for (const row of rows) {
    if (row.document?.fields?.status?.stringValue !== "active") continue;
    const id = row.document.fields?.caregiverId?.stringValue;
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(id)) continue;
    recipients.set(id, {
      id,
      email: row.document.fields?.caregiverEmail?.stringValue?.trim().toLowerCase() ?? "",
    });
  }
  return [...recipients.values()];
}

async function caregiverIds(env: EmergencyEnv, uid: string, token: string): Promise<string[]> {
  return (await caregiverRecipients(env, uid, token)).map(recipient => recipient.id);
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]!);
}

async function emergencyEmailIdempotencyKey(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  const bytes = [...new Uint8Array(digest).slice(0, 16)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.map(byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function deliverEmergencyEmails(
  env: EmergencyEnv,
  uid: string,
  alertId: string,
  elderlyName: string,
  detectedAt: Date,
  token: string,
  recipients: CaregiverRecipient[],
  isFall: boolean,
): Promise<{ emailAccepted: number; emailUnavailable: number; emailError?: string }> {
  let emailAccepted = 0, emailUnavailable = 0;
  if (!env.BREVO_API_KEY || !env.BREVO_SENDER_EMAIL) return {
    emailAccepted, emailUnavailable: recipients.length,
    emailError: "Emergency email is not configured.",
  };
  for (const recipient of recipients) {
    try {
      let email = recipient.email;
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        const user = await read(env, `users/${recipient.id}`, token).catch(() => null);
        email = user?.fields?.email?.stringValue?.trim().toLowerCase() ?? "";
      }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { emailUnavailable++; continue; }
      const receipt = `_email-deliveries/${isFall ? "fall" : "sos"}/${uid}/${alertId}/${recipient.id}`;
      if (await env.MEDICATION_IMAGES.head(receipt)) { emailAccepted++; continue; }
      const idempotencyKey = await emergencyEmailIdempotencyKey(receipt);
      const safeName = escapeHtml(elderlyName);
      const localTime = detectedAt.toLocaleString("en-MY", { timeZone: "Asia/Kuala_Lumpur" });
      const response = await fetch("https://api.brevo.com/v3/smtp/email", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "api-key": env.BREVO_API_KEY,
        },
        body: JSON.stringify({
          sender: {
            name: env.BREVO_SENDER_NAME?.trim() || "SHCA Emergency Alert",
            email: env.BREVO_SENDER_EMAIL.trim(),
          },
          to: [{ email }],
          subject: isFall ? `Urgent: possible fall detected for ${elderlyName}` : `Urgent: SOS help requested by ${elderlyName}`,
          textContent:
            `SHCA ${isFall ? "detected a possible fall for" : "received an SOS help request from"} ${elderlyName} at ${localTime}.\n\n` +
            "Please contact them immediately and check the SHCA caregiver app for the active alert. Call emergency services if they may be injured or cannot respond.",
          htmlContent:
            `<h2 style="color:#c62828">${isFall ? "Possible fall detected" : "SOS help requested"}</h2>` +
            `<p>SHCA ${isFall ? "detected a possible fall for" : "received an SOS help request from"} <strong>${safeName}</strong> at <strong>${escapeHtml(localTime)}</strong>.</p>` +
            `<p>Please contact them immediately and check the SHCA caregiver app for the active alert.</p>` +
            `<p><strong>Call emergency services if they may be injured or cannot respond.</strong></p>`,
          headers: { idempotencyKey },
          tags: [isFall ? "fall-alert" : "sos-alert"],
        }),
      });
      if (!response.ok) {
        console.error("Brevo emergency email failed", { status: response.status, caregiverId: recipient.id });
        emailUnavailable++;
        continue;
      }
      await env.MEDICATION_IMAGES.put(
        receipt,
        JSON.stringify({ sentAt: new Date().toISOString() }),
        { httpMetadata: { contentType: "application/json" } },
      );
      emailAccepted++;
    } catch {
      emailUnavailable++;
      console.error("Emergency email delivery failed", { caregiverId: recipient.id });
    }
  }
  return { emailAccepted, emailUnavailable,
    ...(emailUnavailable > 0 ? { emailError: "Some caregiver emails could not be accepted. Check the caregiver email address or email service." } : {}),
  };
}

async function deliverPush(
  env: EmergencyEnv,
  uid: string,
  alertId: string,
  token: string,
  linked?: string[],
): Promise<Response> {
  const cached = await env.MEDICATION_IMAGES.get(`_push-deliveries/${uid}/${alertId}/result`);
  if (cached) return reply(await cached.json());
  const caregivers = linked ?? await caregiverIds(env, uid, token);
  let accepted = 0, unavailable = 0;
  const pushIssues: string[] = [];
  const lockKey = `_push-deliveries/${uid}/${alertId}/lock`;
  const existingLock = await env.MEDICATION_IMAGES.head(lockKey);
  if (existingLock && existingLock.uploaded.getTime() > Date.now() - 90000) return reply({ error: "Push request is already processing." }, 429);
  const lock = await env.MEDICATION_IMAGES.put(lockKey, "", {
    onlyIf: existingLock ? { etagMatches: existingLock.etag } : { etagDoesNotMatch: "*" },
  });
  if (!lock) return reply({ error: "Push request is already processing." }, 429);
  try {
    for (const caregiverId of caregivers) {
      const profile = await read(env, `caregiver_profiles/${caregiverId}`, token);
      if (profile?.fields?.alertPreferences?.mapValue?.fields?.pushAlert?.booleanValue === false) { unavailable++; pushIssues.push("push_disabled"); continue; }
      const response = await fetch(`${base(env)}/caregiver_profiles/${caregiverId}/push_tokens?pageSize=100`, { headers: { authorization: `Bearer ${token}` } });
      if (!response.ok) { unavailable++; pushIssues.push("tokens_unavailable"); continue; }
      const tokens = await response.json() as { documents?: Doc[] };
      const devices = (tokens.documents ?? []).filter(entry =>
        typeof entry.fields?.token?.stringValue === "string" &&
        entry.fields.token.stringValue.length > 0 && entry.fields?.userId?.stringValue === caregiverId);
      if (devices.length === 0) { unavailable++; pushIssues.push("no_registered_device"); }
      for (const entry of devices) {
        const deviceToken = entry.fields?.token?.stringValue;
        if (typeof deviceToken !== "string" || entry.fields?.userId?.stringValue !== caregiverId) continue;
        const receipt = `_push-deliveries/${uid}/${alertId}/${entry.name?.split("/").pop()}`;
        if (await env.MEDICATION_IMAGES.head(receipt)) { accepted++; continue; }
        const sent = await fetch(`https://fcm.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: JSON.stringify({ message: { token: deviceToken,
            notification: { title: "SHCA: help requested", body: "Your linked elderly user needs assistance. Open SHCA to check the alert." },
            data: { alertId, elderlyId: uid, type: "emergency" },
            android: { priority: "high", ttl: "900s", notification: { channel_id: "shca_emergency_alerts_v2", tag: alertId } },
          } }),
        });
        if (sent.ok) {
          accepted++;
          await env.MEDICATION_IMAGES.put(receipt, JSON.stringify({ acceptedAt: new Date().toISOString() }));
        } else if (sent.status === 401 || sent.status === 403) {
          return reply({ accepted, unavailable: unavailable + 1, linkedCaregivers: caregivers.length, pushIssues: [...pushIssues, "authorization_failed"], error: "Caregiver push authorization failed." }, 503);
        } else { unavailable++; pushIssues.push("device_rejected"); }
      }
    }
    const issueMessages: Record<string, string> = {
      push_disabled: "Push alerts are switched off in the caregiver profile.",
      no_registered_device: "No caregiver phone is registered for push. Sign in to SHCA on the caregiver phone and allow notifications.",
      tokens_unavailable: "The caregiver device registration could not be checked.",
      device_rejected: "Firebase could not accept a caregiver device token. Reopen SHCA on the caregiver phone and check notification permission.",
    };
    const error = caregivers.length === 0 ? "No active caregiver is linked to this account."
      : [...new Set(pushIssues)].map(issue => issueMessages[issue]).join(" ");
    const result = { accepted, unavailable, linkedCaregivers: caregivers.length, pushIssues: [...new Set(pushIssues)],
      ...(error ? { error } : {}) };
    if (accepted > 0 && unavailable === 0) await env.MEDICATION_IMAGES.put(`_push-deliveries/${uid}/${alertId}/result`, JSON.stringify(result));
    return reply(result);
  } finally { await env.MEDICATION_IMAGES.delete(lockKey); }
}

/** Each channel runs independently; a push failure must not suppress email. */
async function deliverEmergency(
  env: EmergencyEnv, uid: string, alertId: string, name: string, detectedAt: Date,
  token: string, recipients: CaregiverRecipient[], isFall: boolean,
): Promise<Response> {
  const [push, email] = await Promise.allSettled([
    deliverPush(env, uid, alertId, token, recipients.map(recipient => recipient.id)),
    deliverEmergencyEmails(env, uid, alertId, name, detectedAt, token, recipients, isFall),
  ]);
  const pushResponse = push.status === "fulfilled" ? push.value : reply({
    accepted: 0, unavailable: recipients.length, linkedCaregivers: recipients.length,
    error: "Caregiver push could not be reached.",
  }, 502);
  const emailResult = email.status === "fulfilled" ? email.value : {
    emailAccepted: 0, emailUnavailable: recipients.length, emailError: "Emergency email could not be reached.",
  };
  return reply({ ...await pushResponse.json() as object, ...emailResult }, pushResponse.status);
}

/** Caller chooses only an alert ID. Recipient links/tokens are resolved server-side. */
export async function sendEmergencyPush(request: Request, env: EmergencyEnv, uid: string, idToken: string): Promise<Response> {
  if (!env.FIREBASE_SERVICE_ACCOUNT) return reply({ error: "Caregiver push is not configured yet." }, 503);
  const body = await request.json().catch(() => null) as { alertId?: unknown } | null;
  if (typeof body?.alertId !== "string" || !/^[A-Za-z0-9_-]{1,260}$/.test(body.alertId)) return reply({ error: "Invalid alert." }, 400);
  const alertId = body.alertId;
  const [alert, user] = await Promise.all([
    read(env, `emergency_alerts/${alertId}`, idToken),
    read(env, `users/${uid}`, idToken),
  ]);
  if (alert?.fields?.elderlyId?.stringValue !== uid || user?.fields?.role?.stringValue !== "elderly") return reply({ error: "You cannot send this alert." }, 403);
  const createdAt = Date.parse(alert.fields.createdAt?.timestampValue ?? "");
  if (!Number.isFinite(createdAt) || Math.abs(Date.now() - createdAt) > 15 * 60000) return reply({ error: "This alert has expired." }, 409);
  let token: string;
  try { token = await googleToken(env); } catch { return reply({ error: "Caregiver push credentials need attention." }, 503); }
  try {
    const recipients = await caregiverRecipients(env, uid, token);
    const type = alert.fields?.type?.stringValue ?? "";
    const activity = alert.fields?.activity?.stringValue ?? "";
    const isFall = type === "possible_fall" || type === "wearable_fall" || /fall/i.test(activity);
    const name = alert.fields?.elderlyName?.stringValue ??
      user.fields?.fullName?.stringValue ?? "Elderly user";
    return await deliverEmergency(env, uid, alertId, name, new Date(createdAt), token, recipients, isFall);
  } catch {
    return reply({ error: "Caregiver links could not be checked." }, 502);
  }
}

interface WatchRequest {
  credentialId?: unknown;
  eventId?: unknown;
  createdAt?: unknown;
  source?: unknown;
  fallProbabilityPpm?: unknown;
  signature?: unknown;
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

async function verifyWatchSignature(publicKey: string, signature: string, message: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      decodeBase64(publicKey),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      decodeBase64(signature),
      new TextEncoder().encode(message),
    );
  } catch {
    return false;
  }
}

function fields(values: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(values).map(([key, value]) => {
    if (typeof value === "string") return [key, { stringValue: value }];
    if (typeof value === "boolean") return [key, { booleanValue: value }];
    if (typeof value === "number") return [key, { doubleValue: value }];
    if (value instanceof Date) return [key, { timestampValue: value.toISOString() }];
    if (Array.isArray(value)) return [key, { arrayValue: { values: value.map(item => ({ stringValue: item })) } }];
    throw new Error(`Unsupported Firestore field: ${key}`);
  }));
}

async function createDocument(env: EmergencyEnv, path: string, values: Record<string, unknown>, token: string): Promise<boolean> {
  const response = await fetch(`${base(env)}/${path}?currentDocument.exists=false`, {
    method: "PATCH",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ fields: fields(values) }),
  });
  return response.ok || response.status === 409;
}

/**
 * Accepts a hardware-signed request from the enrolled Wear OS device. The
 * watch private key is non-exportable and the phone is not needed at send time.
 */
export async function sendWatchEmergency(request: Request, env: EmergencyEnv): Promise<Response> {
  if (!env.FIREBASE_SERVICE_ACCOUNT || !env.FIREBASE_WEB_API_KEY) return reply({ error: "Direct watch alerts are not configured yet." }, 503);
  const body = await request.json().catch(() => null) as WatchRequest | null;
  const credentialId = typeof body?.credentialId === "string" ? body.credentialId : "";
  const eventId = typeof body?.eventId === "string" ? body.eventId : "";
  const createdAt = typeof body?.createdAt === "number" ? body.createdAt : 0;
  const source = body?.source;
  const probabilityPpm = typeof body?.fallProbabilityPpm === "number" ? body.fallProbabilityPpm : -1;
  const signature = typeof body?.signature === "string" ? body.signature : "";
  if (!/^[a-f0-9]{40}$/.test(credentialId) || !/^[A-Za-z0-9_-]{1,100}$/.test(eventId) ||
      !Number.isSafeInteger(createdAt) || Math.abs(Date.now() - createdAt) > 15 * 60000 ||
      (source !== "wearable_sos" && source !== "wearable_fall") ||
      !Number.isInteger(probabilityPpm) || probabilityPpm < 0 || probabilityPpm > 1_000_000 ||
      signature.length < 300 || signature.length > 500) {
    return reply({ error: "Invalid or expired watch alert." }, 400);
  }
  let token: string;
  try { token = await googleToken(env); } catch { return reply({ error: "Caregiver push credentials need attention." }, 503); }
  const credential = await read(env, `watch_credentials/${credentialId}`, token);
  const uid = credential?.fields?.elderlyId?.stringValue;
  const publicKey = credential?.fields?.publicKey?.stringValue;
  if (credential?.fields?.active?.booleanValue !== true ||
      credential?.fields?.algorithm?.stringValue !== "RS256" ||
      typeof uid !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(uid) ||
      typeof publicKey !== "string") {
    return reply({ error: "This watch is not enrolled." }, 401);
  }
  const canonical = [credentialId, eventId, String(createdAt), source, String(probabilityPpm)].join("\n");
  if (!await verifyWatchSignature(publicKey, signature, canonical)) {
    return reply({ error: "Watch signature could not be verified." }, 401);
  }
  const [user, elderly, recipients] = await Promise.all([
    read(env, `users/${uid}`, token),
    read(env, `elderly_profiles/${uid}`, token),
    caregiverRecipients(env, uid, token),
  ]);
  if (user?.fields?.role?.stringValue !== "elderly") return reply({ error: "This watch account is unavailable." }, 403);
  const linked = recipients.map(recipient => recipient.id);
  const alertId = `watch_${uid}_${eventId}`;
  const detectedAt = new Date(createdAt);
  const probability = probabilityPpm / 1_000_000;
  const name = elderly?.fields?.fullName?.stringValue ?? user.fields?.fullName?.stringValue ?? "Elderly user";
  const phone = elderly?.fields?.emergencyContact?.mapValue?.fields?.phone?.stringValue ?? "";
  let userToken: string;
  try { userToken = await firebaseUserToken(env, uid); } catch { return reply({ error: "The watch alert could not be authorized." }, 503); }
  const created = await createDocument(env, `emergency_alerts/${alertId}`, {
    elderlyId: uid,
    elderlyName: name,
    type: source,
    status: "active",
    activity: source === "wearable_fall" ? "Possible fall" : "Watch emergency",
    fallProbability: probability,
    sensorSource: "watch",
    emergencyContactPhone: phone,
    recipientCaregiverIds: linked,
    watchEventId: eventId,
    createdAt: detectedAt,
  }, userToken);
  if (!created) return reply({ error: "The watch alert could not be saved." }, 502);
  if (source === "wearable_fall") {
    await createDocument(env, `fall_events/${alertId}`, {
      elderlyId: uid,
      source: "wearable",
      status: "alert_sent",
      activity: "Possible fall",
      fallProbability: probability,
      confidence: 0,
      detectedAt,
    }, userToken);
  }
  try {
    return await deliverEmergency(env, uid, alertId, name, detectedAt, token, recipients, source === "wearable_fall");
  } catch {
    return reply({ error: "The alert was saved, but caregiver delivery could not be checked." }, 502);
  }
}
