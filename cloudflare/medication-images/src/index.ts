import { issueWatchSignInToken } from "./watch_sign_in.ts";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { sendEmergencyPush, sendWatchEmergency } from "./emergency.ts";
import {
  openWatchSession,
  saveWatchActivity,
  saveWatchMedicationAction,
  watchSnapshot,
} from "./watch.ts";
import { generateStatisticsForecast } from "./statistics.ts";

interface Env {
  MEDICATION_IMAGES: R2Bucket;
  FIREBASE_PROJECT_ID: string;
  FIREBASE_WEB_API_KEY?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
  ALLOWED_ORIGIN?: string;
  BREVO_API_KEY?: string;
  BREVO_SENDER_EMAIL?: string;
  BREVO_SENDER_NAME?: string;
  GROQ_API_KEY?: string;
  GROQ_MODEL?: string;
}

interface FirestoreDocument {
  name?: string;
  fields?: Record<string, FirestoreValue>;
}

interface FirestoreValue {
  stringValue?: string;
  booleanValue?: boolean;
  integerValue?: string;
}

const firebaseKeys = createRemoteJWKSet(
  new URL(
    "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com",
  ),
);
const maxImageBytes = 5 * 1024 * 1024;
const allowedImageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      if (request.method === "OPTIONS") return corsResponse(request, env);
      const url = new URL(request.url);
      if (url.pathname === "/v1/watch-emergency" && request.method === "POST") {
        return await sendWatchEmergency(request, env);
      }
      const { uid, token } = await authenticate(request, env);
      if (url.pathname === "/v1/watch/sign-in-token" && request.method === "POST") {
        return await issueWatchSignInToken(request, env, uid, token);
      }
      if (url.pathname === "/v1/watch/session" && request.method === "POST") {
        return await openWatchSession(request, env, uid, token);
      }
      if (url.pathname === "/v1/watch/snapshot" && request.method === "POST") {
        return await watchSnapshot(request, env, uid, token);
      }
      if (url.pathname === "/v1/watch/activity" && request.method === "POST") {
        return await saveWatchActivity(request, env, uid, token);
      }
      if (url.pathname === "/v1/watch/medication-action" && request.method === "POST") {
        return await saveWatchMedicationAction(request, env, uid, token);
      }
      if (url.pathname === "/v1/emergency-alerts/push" && request.method === "POST") {
        return await sendEmergencyPush(request, env, uid, token);
      }
      if (url.pathname === "/v1/statistics/forecast" && request.method === "POST") {
        return await generateStatisticsForecast(request, env, uid, token);
      }
      if (url.pathname === "/v1/medication-images") {
        if (request.method === "POST") {
          return await uploadImage(request, env, uid, token);
        }
        if (request.method === "GET") {
          return await readImage(request, env, uid, token);
        }
        if (request.method === "DELETE") {
          return await deleteImage(request, env, uid, token);
        }
      } else if (url.pathname === "/v1/medication-reminders/email") {
        if (request.method === "POST") {
          return await sendMedicationReminderEmail(request, env, uid, token);
        }
      } else if (url.pathname === "/v1/medication-stock/email") {
        if (request.method === "POST") {
          return await sendLowStockEmail(request, env, uid, token);
        }
      } else {
        return json({ error: "Not found." }, 404, request, env);
      }
      return json({ error: "Method not allowed." }, 405, request, env);
    } catch (error) {
      const message = error instanceof RequestError
        ? error.message
        : "The SHCA service could not complete the request.";
      const status = error instanceof RequestError ? error.status : 500;
      return json({ error: message }, status, request, env);
    }
  },
};

export async function sendMedicationReminderEmail(
  request: Request,
  env: Env,
  uid: string,
  token: string,
): Promise<Response> {
  if (!env.BREVO_API_KEY || !env.BREVO_SENDER_EMAIL) {
    throw new RequestError(
      503,
      "Caregiver email reminders have not been configured yet.",
    );
  }
  const body = await request.json().catch(() => null) as Record<
    string,
    unknown
  > | null;
  if (body === null) throw new RequestError(400, "Invalid JSON request.");
  const elderlyId = requiredIdentifier(body.elderlyId, "elderlyId");
  const medicationId = requiredIdentifier(body.medicationId, "medicationId");
  const occurrenceDate = typeof body.occurrenceDate === "string"
    ? body.occurrenceDate
    : "";
  if (elderlyId !== uid) {
    throw new RequestError(
      403,
      "Only the elderly account can send this reminder.",
    );
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(occurrenceDate)) {
    throw new RequestError(400, "Invalid reminder date.");
  }

  const medication = await firestoreDocument(
    `medications/${elderlyId}_${medicationId}`,
    token,
    env,
  );
  if (
    medication.fields?.elderlyId?.stringValue !== elderlyId ||
    medication.fields?.active?.booleanValue === false
  ) {
    throw new RequestError(404, "The medication schedule is not active.");
  }
  const record = await firestoreDocument(
    `medication_records/${elderlyId}_${occurrenceDate}_${medicationId}`,
    token,
    env,
  );
  if (
    record.fields?.elderlyId?.stringValue !== elderlyId ||
    record.fields?.medicationId?.stringValue !== medicationId ||
    record.fields?.status?.stringValue !== "missed"
  ) {
    throw new RequestError(
      409,
      "Caregiver email is sent only after this dose is marked missed.",
    );
  }
  const links = await linkedCaregiverDocuments(elderlyId, token, env);
  const elderlyProfile = await firestoreDocument(
    `elderly_profiles/${elderlyId}`,
    token,
    env,
  ).catch(() => null);
  const elderlyName = safeText(
    elderlyProfile?.fields?.fullName?.stringValue,
    "your linked elderly user",
  );
  const medicineName = safeText(
    medication.fields?.name?.stringValue,
    "Medication",
  );
  const dose = medicationDoseSummary(medication.fields);
  const instruction = safeText(
    medication.fields?.instruction?.stringValue,
    "Follow the supplied instructions",
  );
  const hour = numericValue(medication.fields?.hour, 8);
  const minute = numericValue(medication.fields?.minute, 0);
  const scheduledTime = formatTime(hour, minute);

  let sent = 0;
  let alreadySent = 0;
  let unavailable = 0;
  let missingEmail = 0;
  let disabled = 0;
  for (const link of links) {
    if (link.fields?.medicationEmailAlertsEnabled?.booleanValue === false) {
      unavailable++;
      disabled++;
      continue;
    }
    const caregiverId = link.fields?.caregiverId?.stringValue ?? "";
    const caregiverEmail = link.fields?.caregiverEmail?.stringValue
      ?.trim()
      .toLowerCase() ?? "";
    if (
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(caregiverEmail) ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(caregiverId)
    ) {
      unavailable++;
      missingEmail++;
      continue;
    }
    const deliveryKey =
      `_email-deliveries/missed/${occurrenceDate}/${elderlyId}/${medicationId}/${caregiverId}`;
    if (await env.MEDICATION_IMAGES.head(deliveryKey)) {
      alreadySent++;
      continue;
    }
    const idempotencyKey = await deterministicUuid(deliveryKey);
    await sendBrevoMissedMedicationEmail(env, {
      to: caregiverEmail,
      elderlyName,
      medicineName,
      dose,
      instruction,
      scheduledTime,
      idempotencyKey,
    });
    await env.MEDICATION_IMAGES.put(
      deliveryKey,
      JSON.stringify({ sentAt: new Date().toISOString() }),
      { httpMetadata: { contentType: "application/json" } },
    );
    sent++;
  }
  return json({
    sent,
    alreadySent,
    unavailable,
    linkedCaregivers: links.length,
    missingEmail,
    disabled,
  }, 200, request, env);
}

async function sendLowStockEmail(
  request: Request,
  env: Env,
  uid: string,
  token: string,
): Promise<Response> {
  if (!env.BREVO_API_KEY || !env.BREVO_SENDER_EMAIL) {
    throw new RequestError(
      503,
      "Caregiver email reminders have not been configured yet.",
    );
  }
  const body = await request.json().catch(() => null) as Record<
    string,
    unknown
  > | null;
  if (body === null) throw new RequestError(400, "Invalid JSON request.");
  const elderlyId = requiredIdentifier(body.elderlyId, "elderlyId");
  const medicationId = requiredIdentifier(body.medicationId, "medicationId");
  const occurrenceDate = typeof body.occurrenceDate === "string"
    ? body.occurrenceDate
    : "";
  if (elderlyId !== uid) {
    throw new RequestError(
      403,
      "Only the elderly account can send this reminder.",
    );
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(occurrenceDate)) {
    throw new RequestError(400, "Invalid reminder date.");
  }

  const medication = await firestoreDocument(
    `medications/${elderlyId}_${medicationId}`,
    token,
    env,
  );
  if (
    medication.fields?.elderlyId?.stringValue !== elderlyId ||
    medication.fields?.active?.booleanValue === false
  ) {
    throw new RequestError(404, "The medication schedule is not active.");
  }
  const remaining = numericValue(medication.fields?.stockRemaining, -1);
  const threshold = numericValue(medication.fields?.lowStockThreshold, 3);
  if (remaining < 0 || remaining > threshold) {
    throw new RequestError(409, "This medicine is not currently running low.");
  }

  const links = await linkedCaregiverDocuments(elderlyId, token, env);
  const elderlyProfile = await firestoreDocument(
    `elderly_profiles/${elderlyId}`,
    token,
    env,
  ).catch(() => null);
  const elderlyName = safeText(
    elderlyProfile?.fields?.fullName?.stringValue,
    "your linked elderly user",
  );
  const medicineName = safeText(
    medication.fields?.name?.stringValue,
    "Medication",
  );
  const dose = medicationDoseSummary(medication.fields);

  let sent = 0;
  let alreadySent = 0;
  let unavailable = 0;
  let missingEmail = 0;
  let disabled = 0;
  for (const link of links) {
    if (link.fields?.medicationEmailAlertsEnabled?.booleanValue === false) {
      unavailable++;
      disabled++;
      continue;
    }
    const caregiverId = link.fields?.caregiverId?.stringValue ?? "";
    const caregiverEmail = link.fields?.caregiverEmail?.stringValue
      ?.trim()
      .toLowerCase() ?? "";
    if (
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(caregiverEmail) ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(caregiverId)
    ) {
      unavailable++;
      missingEmail++;
      continue;
    }
    const deliveryKey =
      `_email-deliveries/low-stock/${occurrenceDate}/${elderlyId}/${medicationId}/${caregiverId}`;
    if (await env.MEDICATION_IMAGES.head(deliveryKey)) {
      alreadySent++;
      continue;
    }
    const idempotencyKey = await deterministicUuid(deliveryKey);
    await sendBrevoLowStockEmail(env, {
      to: caregiverEmail,
      elderlyName,
      medicineName,
      dose,
      remaining,
      idempotencyKey,
    });
    await env.MEDICATION_IMAGES.put(
      deliveryKey,
      JSON.stringify({ sentAt: new Date().toISOString() }),
      { httpMetadata: { contentType: "application/json" } },
    );
    sent++;
  }
  return json({
    sent,
    alreadySent,
    unavailable,
    linkedCaregivers: links.length,
    missingEmail,
    disabled,
  }, 200, request, env);
}

async function linkedCaregiverDocuments(
  elderlyId: string,
  token: string,
  env: Env,
): Promise<FirestoreDocument[]> {
  const response = await fetch(firestoreBase(env) + "/documents:runQuery", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: "care_links" }],
        where: {
          compositeFilter: {
            op: "AND",
            filters: [
              {
                fieldFilter: {
                  field: { fieldPath: "elderlyId" },
                  op: "EQUAL",
                  value: { stringValue: elderlyId },
                },
              },
              {
                fieldFilter: {
                  field: { fieldPath: "status" },
                  op: "EQUAL",
                  value: { stringValue: "active" },
                },
              },
            ],
          },
        },
      },
    }),
  });
  if (!response.ok) {
    throw new RequestError(502, "Linked caregivers could not be loaded.");
  }
  const rows = await response.json() as Array<{
    document?: FirestoreDocument;
  }>;
  return rows.flatMap((row) => row.document ? [row.document] : []);
}

async function firestoreDocument(
  path: string,
  token: string,
  env: Env,
): Promise<FirestoreDocument> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  const response = await fetch(
    `${firestoreBase(env)}/documents/${encodedPath}`,
    { headers: { authorization: `Bearer ${token}` } },
  );
  if (!response.ok) {
    throw new RequestError(
      response.status === 404 ? 404 : 502,
      "Required reminder data could not be loaded.",
    );
  }
  return await response.json() as FirestoreDocument;
}

function firestoreBase(env: Env): string {
  return `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID)}/databases/(default)`;
}

async function sendBrevoMissedMedicationEmail(
  env: Env,
  values: {
    to: string;
    elderlyName: string;
    medicineName: string;
    dose: string;
    instruction: string;
    scheduledTime: string;
    idempotencyKey: string;
  },
): Promise<void> {
  const escaped = Object.fromEntries(
    Object.entries(values).map(([key, value]) => [key, escapeHtml(value)]),
  ) as Record<keyof typeof values, string>;
  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      "api-key": env.BREVO_API_KEY!,
    },
    body: JSON.stringify({
      sender: {
        name: env.BREVO_SENDER_NAME?.trim() || "SHCA Medication Reminder",
        email: env.BREVO_SENDER_EMAIL!.trim(),
      },
      to: [{ email: values.to }],
      subject: `Missed medication for ${values.elderlyName}`,
      textContent:
        `${values.elderlyName} missed the medicine scheduled for ${values.scheduledTime}.\n\n` +
        `${values.medicineName}\nDose: ${values.dose}\nInstruction: ${values.instruction}\n\n` +
        "Please check in and follow the existing clinician or medicine-label instructions. Do not give an extra dose unless a clinician has advised it.",
      htmlContent:
        `<h2>Missed medication</h2>` +
        `<p><strong>${escaped.elderlyName}</strong> missed the medicine scheduled for ` +
        `<strong>${escaped.scheduledTime}</strong>.</p>` +
        `<div style="border:1px solid #f3c6a7;border-radius:12px;padding:16px">` +
        `<h3 style="margin-top:0">${escaped.medicineName}</h3>` +
        `<p><strong>Dose:</strong> ${escaped.dose}<br>` +
        `<strong>Instruction:</strong> ${escaped.instruction}</p></div>` +
        `<p>Please check in and follow the existing clinician or medicine-label instructions.</p>` +
        `<p style="color:#6b625d;font-size:12px">Do not give an extra dose unless a clinician has advised it.</p>`,
      headers: { idempotencyKey: values.idempotencyKey },
      tags: ["medication-missed"],
    }),
  });
  if (!response.ok) {
    throw await brevoRequestError(response, "reminder");
  }
}

async function sendBrevoLowStockEmail(
  env: Env,
  values: {
    to: string;
    elderlyName: string;
    medicineName: string;
    dose: string;
    remaining: number;
    idempotencyKey: string;
  },
): Promise<void> {
  const elderlyName = escapeHtml(values.elderlyName);
  const medicineName = escapeHtml(values.medicineName);
  const dose = escapeHtml(values.dose);
  const tabletLabel = values.remaining === 1 ? "tablet" : "tablets";
  const response = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      "api-key": env.BREVO_API_KEY!,
    },
    body: JSON.stringify({
      sender: {
        name: env.BREVO_SENDER_NAME?.trim() || "SHCA Medication Reminder",
        email: env.BREVO_SENDER_EMAIL!.trim(),
      },
      to: [{ email: values.to }],
      subject: `Medicine running low for ${values.elderlyName}`,
      textContent:
        `${values.elderlyName}'s ${values.medicineName} is running low.\n\n` +
        `Remaining: ${values.remaining} ${tabletLabel}\nDose: ${values.dose}\n\n` +
        "Please check the medicine supply and arrange a refill using the existing clinician or pharmacy instructions.",
      htmlContent:
        `<h2>Medicine running low</h2>` +
        `<p><strong>${elderlyName}</strong>'s medicine supply needs attention.</p>` +
        `<div style="border:1px solid #f3c6a7;border-radius:12px;padding:16px">` +
        `<h3 style="margin-top:0">${medicineName}</h3>` +
        `<p><strong>Remaining:</strong> ${values.remaining} ${tabletLabel}<br>` +
        `<strong>Dose:</strong> ${dose}</p></div>` +
        `<p>Please check the supply and arrange a refill using the existing clinician or pharmacy instructions.</p>` +
        `<p style="color:#6b625d;font-size:12px">SHCA does not prescribe medicine or authorize dosage changes.</p>`,
      headers: { idempotencyKey: values.idempotencyKey },
      tags: ["medication-low-stock"],
    }),
  });
  if (!response.ok) {
    throw await brevoRequestError(response, "low-stock reminder");
  }
}

async function brevoRequestError(
  response: Response,
  reminderType: string,
): Promise<RequestError> {
  const body = await response.json().catch(() => null) as {
    code?: string;
    message?: string;
  } | null;
  const providerCode = body?.code?.toLowerCase() ?? "";
  const providerMessage = body?.message?.toLowerCase() ?? "";
  console.error("Brevo email request failed", {
    status: response.status,
    code: providerCode || "unknown",
  });
  if (response.status === 401 || response.status === 403) {
    return new RequestError(
      502,
      "Brevo rejected the email service key. Create a new Brevo API key and update the Cloudflare secret.",
    );
  }
  if (providerMessage.includes("sender") || providerCode.includes("sender")) {
    return new RequestError(
      502,
      "Brevo rejected the sender address. Verify the sender in Brevo and try again.",
    );
  }
  if (response.status === 402 || response.status === 429) {
    return new RequestError(
      502,
      "Brevo cannot send more email right now because the free-plan limit or rate limit was reached.",
    );
  }
  return new RequestError(
    502,
    `Brevo could not send the ${reminderType}. Check the Brevo transactional email setup and try again.`,
  );
}

function numericValue(
  value: FirestoreValue | undefined,
  fallback: number,
): number {
  const parsed = Number(value?.integerValue);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function medicationDoseSummary(
  fields: Record<string, FirestoreValue> | undefined,
): string {
  const rawDose = safeText(fields?.dose?.stringValue, "");
  const quantity = Math.max(1, Math.trunc(numericValue(fields?.quantity, 1)));
  const visual = safeText(fields?.visual?.stringValue, "tablet").toLowerCase();
  const unit = visual === "capsule"
    ? "capsule"
    : visual === "liquid"
    ? "dose"
    : "tablet";
  const quantityLabel = `${quantity} ${unit}${quantity === 1 ? "" : "s"}`;
  const legacyQuantity = /^\s*\d+\s*(?:tablets?|capsules?|doses?)\s*$/i
    .test(rawDose);
  return rawDose.length === 0 || legacyQuantity
    ? quantityLabel
    : `${rawDose} • ${quantityLabel}`;
}

function formatTime(hour: number, minute: number): string {
  const normalizedHour = ((hour % 24) + 24) % 24;
  const suffix = normalizedHour < 12 ? "AM" : "PM";
  const displayHour = normalizedHour % 12 || 12;
  return `${displayHour}:${Math.max(0, Math.min(59, minute)).toString().padStart(2, "0")} ${suffix}`;
}

function safeText(value: string | undefined, fallback: string): string {
  const trimmed = value?.trim() ?? "";
  return trimmed.length > 0 && trimmed.length <= 200 ? trimmed : fallback;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character] ?? character);
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function deterministicUuid(value: string): Promise<string> {
  const characters = (await sha256Hex(value)).slice(0, 32).split("");
  // UUID version 5 and RFC 4122 variant bits. The digest keeps the value
  // stable for a delivery key while satisfying Brevo's UUID requirement.
  characters[12] = "5";
  characters[16] = (
    (Number.parseInt(characters[16], 16) & 0x3) | 0x8
  ).toString(16);
  const hex = characters.join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function uploadImage(
  request: Request,
  env: Env,
  caregiverId: string,
  token: string,
): Promise<Response> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > maxImageBytes + 256 * 1024) {
    throw new RequestError(413, "The medicine photo must be smaller than 5 MB.");
  }
  const form = await request.formData();
  const elderlyId = requiredIdentifier(form.get("elderlyId"), "elderlyId");
  const medicationId = requiredIdentifier(
    form.get("medicationId"),
    "medicationId",
  );
  const file = form.get("file");
  if (!(file instanceof File)) {
    throw new RequestError(400, "A medicine photo is required.");
  }
  if (!allowedImageTypes.has(file.type)) {
    throw new RequestError(415, "Use a JPEG, PNG, or WebP medicine photo.");
  }
  if (file.size <= 0 || file.size > maxImageBytes) {
    throw new RequestError(413, "The medicine photo must be smaller than 5 MB.");
  }
  if (!(await caregiverIsLinked(caregiverId, elderlyId, token, env))) {
    throw new RequestError(403, "This caregiver is not linked to that account.");
  }

  const extension = file.type === "image/png"
    ? "png"
    : file.type === "image/webp"
    ? "webp"
    : "jpg";
  const imageKey = `${elderlyId}/${caregiverId}/${crypto.randomUUID()}.${extension}`;
  await env.MEDICATION_IMAGES.put(imageKey, file.stream(), {
    httpMetadata: { contentType: file.type },
    customMetadata: {
      elderlyId,
      uploadedBy: caregiverId,
      medicationId,
    },
  });
  return json({ imageKey }, 201, request, env);
}

async function readImage(
  request: Request,
  env: Env,
  uid: string,
  token: string,
): Promise<Response> {
  const url = new URL(request.url);
  const elderlyId = requiredIdentifier(
    url.searchParams.get("elderlyId"),
    "elderlyId",
  );
  const imageKey = url.searchParams.get("imageKey")?.trim() ?? "";
  if (!imageKey.startsWith(`${elderlyId}/`) || imageKey.length > 300) {
    throw new RequestError(400, "Invalid private image reference.");
  }
  if (
    uid !== elderlyId &&
    !(await caregiverIsLinked(uid, elderlyId, token, env))
  ) {
    throw new RequestError(403, "You cannot access this medicine photo.");
  }
  const object = await env.MEDICATION_IMAGES.get(imageKey);
  if (object === null || object.customMetadata?.elderlyId !== elderlyId) {
    throw new RequestError(404, "Medicine photo not found.");
  }
  const headers = corsHeaders(request, env);
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", "private, max-age=300");
  headers.set("x-content-type-options", "nosniff");
  return new Response(object.body, { headers });
}

async function deleteImage(
  request: Request,
  env: Env,
  caregiverId: string,
  token: string,
): Promise<Response> {
  const url = new URL(request.url);
  const elderlyId = requiredIdentifier(
    url.searchParams.get("elderlyId"),
    "elderlyId",
  );
  const imageKey = url.searchParams.get("imageKey")?.trim() ?? "";
  if (!imageKey.startsWith(`${elderlyId}/`) || imageKey.length > 300) {
    throw new RequestError(400, "Invalid private image reference.");
  }
  if (!(await caregiverIsLinked(caregiverId, elderlyId, token, env))) {
    throw new RequestError(403, "This caregiver is not linked to that account.");
  }
  const object = await env.MEDICATION_IMAGES.head(imageKey);
  if (object === null || object.customMetadata?.elderlyId !== elderlyId) {
    throw new RequestError(404, "Medicine photo not found.");
  }
  await env.MEDICATION_IMAGES.delete(imageKey);
  return json({ deleted: true }, 200, request, env);
}

async function authenticate(
  request: Request,
  env: Env,
): Promise<{ uid: string; token: string }> {
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    throw new RequestError(401, "Sign in is required.");
  }
  const token = authorization.slice("Bearer ".length).trim();
  try {
    const result = await jwtVerify(token, firebaseKeys, {
      audience: env.FIREBASE_PROJECT_ID,
      issuer: `https://securetoken.google.com/${env.FIREBASE_PROJECT_ID}`,
      algorithms: ["RS256"],
    });
    const uid = result.payload.sub;
    if (typeof uid !== "string" || uid.length === 0) {
      throw new Error("Missing subject");
    }
    return { uid, token };
  } catch {
    throw new RequestError(401, "Your secure sign-in session has expired.");
  }
}

async function caregiverIsLinked(
  caregiverId: string,
  elderlyId: string,
  token: string,
  env: Env,
): Promise<boolean> {
  const documentId = encodeURIComponent(`${caregiverId}_${elderlyId}`);
  const endpoint =
    `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID)}` +
    `/databases/(default)/documents/care_links/${documentId}`;
  const response = await fetch(endpoint, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!response.ok) return false;
  const document = (await response.json()) as {
    fields?: Record<string, { stringValue?: string }>;
  };
  return (
    document.fields?.caregiverId?.stringValue === caregiverId &&
    document.fields?.elderlyId?.stringValue === elderlyId &&
    document.fields?.status?.stringValue === "active"
  );
}

function requiredIdentifier(
  value: unknown,
  name: string,
): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new RequestError(400, `Invalid ${name}.`);
  }
  return value;
}

function json(
  value: unknown,
  status: number,
  request: Request,
  env: Env,
): Response {
  const headers = corsHeaders(request, env);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(value), { status, headers });
}

function corsResponse(request: Request, env: Env): Response {
  const headers = corsHeaders(request, env);
  headers.set("access-control-allow-methods", "GET, POST, DELETE, OPTIONS");
  headers.set("access-control-allow-headers", "authorization, content-type");
  headers.set("access-control-max-age", "86400");
  return new Response(null, { status: 204, headers });
}

function corsHeaders(request: Request, env: Env): Headers {
  const headers = new Headers();
  const origin = request.headers.get("origin");
  if (origin && env.ALLOWED_ORIGIN && origin === env.ALLOWED_ORIGIN) {
    headers.set("access-control-allow-origin", origin);
    headers.set("vary", "origin");
  }
  return headers;
}

class RequestError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
