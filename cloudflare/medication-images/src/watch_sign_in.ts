import { importPKCS8, SignJWT } from "jose";

interface SignInEnv {
  FIREBASE_PROJECT_ID: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
}

const reply = (value: unknown, status = 200) => Response.json(value, {
  status, headers: { "cache-control": "no-store" },
});

/** Only the authenticated elderly user can grant their own session to a watch.
 * The phone sends the result over the same-package/same-signature Wear Data Layer.
 * No password or caller-supplied account ID is accepted by this endpoint.
 */
export async function issueWatchSignInToken(
  request: Request, env: SignInEnv, uid: string, idToken: string,
): Promise<Response> {
  const body = await request.json().catch(() => null) as { nonce?: unknown } | null;
  if (typeof body?.nonce !== "string" || !/^[a-f0-9]{64}$/.test(body.nonce)) {
    return reply({ error: "Open Connect with phone on the watch and try again." }, 400);
  }
  const response = await fetch(
    `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents/users/${encodeURIComponent(uid)}`,
    { headers: { authorization: `Bearer ${idToken}` } },
  );
  if (!response.ok) return reply({ error: "Your account could not be checked. Try again." }, 503);
  const user = await response.json() as { fields?: Record<string, any> };
  if (user.fields?.role?.stringValue !== "elderly") {
    return reply({ error: "Sign in to the elderly account on the phone to connect this watch." }, 403);
  }
  try {
    const service = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT ?? "{}");
    if (service.project_id !== env.FIREBASE_PROJECT_ID || !service.client_email || !service.private_key) {
      return reply({ error: "Watch sign-in is not configured." }, 503);
    }
    const key = await importPKCS8(service.private_key, "RS256");
    const customToken = await new SignJWT({ uid })
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuer(service.client_email).setSubject(service.client_email)
      .setAudience("https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit")
      .setIssuedAt().setExpirationTime("5m").sign(key);
    return reply({ customToken, nonce: body.nonce });
  } catch {
    return reply({ error: "Watch sign-in could not be prepared. Please try again." }, 503);
  }
}
