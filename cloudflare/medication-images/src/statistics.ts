export interface StatisticsEnv {
  MEDICATION_IMAGES: R2Bucket;
  FIREBASE_PROJECT_ID: string;
  GROQ_API_KEY?: string;
  GROQ_MODEL?: string;
}

interface ForecastRequest {
  elderlyId: string;
  periodDays: number;
  asOf: string;
  totals: {
    taken: number;
    missed: number;
    unresolved: number;
    doses: number;
    possibleFallAlerts: number;
    recordDays: number;
  };
  days: Array<{
    date: string;
    taken: number;
    missed: number;
    unresolved: number;
    possibleFallAlerts: number;
  }>;
  alertHours: number[];
  fallStatuses: Record<string, number>;
}

interface Forecast {
  summary: string;
  predictedCompletion: number;
  completionLower: number;
  completionUpper: number;
  trend: "improving" | "stable" | "declining" | "insufficient_data";
  possibleFallAlertLevel: "low" | "moderate" | "elevated" | "insufficient_data";
  actions: string[];
  limitations: string;
}

const cacheHours = 12;

export async function generateStatisticsForecast(
  request: Request,
  env: StatisticsEnv,
  caregiverId: string,
  token: string,
): Promise<Response> {
  try {
    if (!env.GROQ_API_KEY) {
      throw new ForecastError(
        503,
        "AI forecasting has not been configured yet.",
      );
    }
    const raw = await request.json().catch(() => null);
    const input = parseRequest(raw);
    if (!(await caregiverIsLinked(caregiverId, input.elderlyId, token, env))) {
      throw new ForecastError(
        403,
        "This caregiver is not linked to that account.",
      );
    }
    if (input.totals.doses < 5 || input.totals.recordDays < 3) {
      throw new ForecastError(
        422,
        "At least 3 recorded days and 5 dose records are needed for an AI forecast.",
      );
    }

    const model = safeModel(env.GROQ_MODEL);
    // The account identifier is required for SHCA authorization, but it is
    // deliberately removed before hashing, caching or calling Groq.
    const { elderlyId: _authorizedElderlyId, ...anonymousInput } = input;
    const inputJson = JSON.stringify(anonymousInput);
    const digest = await sha256(`${model}\n${inputJson}`);
    const cacheKey = `_statistics-forecasts/${caregiverId}/${input.elderlyId}/${digest}.json`;
    const cached = await env.MEDICATION_IMAGES.get(cacheKey);
    if (cached && Date.now() - cached.uploaded.getTime() < cacheHours * 3600000) {
      const stored = await cached.json<{
        forecast: Forecast;
        model: string;
        generatedAt: string;
      }>();
      return response({ ...stored, cached: true }, 200);
    }

    const groqResponse = await fetch(
      "https://api.groq.com/openai/v1/chat/completions",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "authorization": `Bearer ${env.GROQ_API_KEY}`,
        },
        body: JSON.stringify({
          model,
          messages: [
            { role: "system", content: systemInstruction },
            {
              role: "user",
              content:
                `Produce a cautious next-7-day forecast from this anonymous aggregate SHCA history:\n${inputJson}`,
            },
          ],
          temperature: 0.2,
          reasoning_effort: "low",
          max_completion_tokens: 1200,
          response_format: {
            type: "json_schema",
            json_schema: {
              name: "shca_statistics_forecast",
              strict: true,
              schema: forecastSchema,
            },
          },
        }),
      },
    );
    if (!groqResponse.ok) {
      const status = groqResponse.status === 429 ? 429 : 502;
      throw new ForecastError(
        status,
        status === 429
          ? "The free AI quota is temporarily exhausted. Try again later."
          : "The AI service could not create a forecast right now.",
      );
    }
    const generated = await groqResponse.json() as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const text = generated.choices?.[0]?.message?.content;
    if (!text) {
      throw new ForecastError(502, "The AI service returned an empty forecast.");
    }
    const forecast = parseForecast(JSON.parse(text));
    const generatedAt = new Date().toISOString();
    const stored = { forecast, model, generatedAt };
    await env.MEDICATION_IMAGES.put(cacheKey, JSON.stringify(stored), {
      httpMetadata: { contentType: "application/json" },
    });
    return response({ ...stored, cached: false }, 200);
  } catch (error) {
    if (error instanceof ForecastError) {
      return response({ error: error.message }, error.status);
    }
    return response(
      { error: "The AI forecast could not be created right now." },
      500,
    );
  }
}

const systemInstruction = `You support a caregiver statistics screen.
Analyze only the anonymous aggregate records supplied by the user. Forecast the next 7 days, assuming schedules and recording habits remain similar.
Medication completion means taken divided by all saved dose records. Unresolved means pending, snoozed or unknown and must not automatically be called missed.
Possible-fall alerts are sensor alerts, not confirmed falls, and the records do not describe monitoring coverage. Do not diagnose, predict an actual fall, or invent medical facts.
Use conservative language. Base the completion estimate and interval on the supplied daily pattern and sample size. A wider interval is required for sparse or inconsistent data.
possibleFallAlertLevel describes only the chance that a similar sensor alert will be recorded: low, moderate, elevated, or insufficient_data.
Return short plain-language text. Give at most three practical caregiver actions. State the main data limitation.`;

const forecastSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    summary: { type: "string" },
    predictedCompletion: { type: "integer", minimum: 0, maximum: 100 },
    completionLower: { type: "integer", minimum: 0, maximum: 100 },
    completionUpper: { type: "integer", minimum: 0, maximum: 100 },
    trend: {
      type: "string",
      enum: ["improving", "stable", "declining", "insufficient_data"],
    },
    possibleFallAlertLevel: {
      type: "string",
      enum: ["low", "moderate", "elevated", "insufficient_data"],
    },
    actions: {
      type: "array",
      minItems: 1,
      maxItems: 3,
      items: { type: "string" },
    },
    limitations: { type: "string" },
  },
  required: [
    "summary",
    "predictedCompletion",
    "completionLower",
    "completionUpper",
    "trend",
    "possibleFallAlertLevel",
    "actions",
    "limitations",
  ],
};

function parseRequest(raw: unknown): ForecastRequest {
  if (!isRecord(raw)) throw new ForecastError(400, "Invalid JSON request.");
  const elderlyId = identifier(raw.elderlyId, "elderlyId");
  const periodDays = integer(raw.periodDays, 7, 90, "periodDays");
  if (![7, 30, 90].includes(periodDays)) {
    throw new ForecastError(400, "Invalid periodDays.");
  }
  const asOf = text(raw.asOf, 40, "asOf");
  if (Number.isNaN(Date.parse(asOf))) throw new ForecastError(400, "Invalid asOf.");
  if (!isRecord(raw.totals)) throw new ForecastError(400, "Invalid totals.");
  const totals = {
    taken: integer(raw.totals.taken, 0, 100000, "totals.taken"),
    missed: integer(raw.totals.missed, 0, 100000, "totals.missed"),
    unresolved: integer(raw.totals.unresolved, 0, 100000, "totals.unresolved"),
    doses: integer(raw.totals.doses, 0, 100000, "totals.doses"),
    possibleFallAlerts: integer(
      raw.totals.possibleFallAlerts,
      0,
      100000,
      "totals.possibleFallAlerts",
    ),
    recordDays: integer(raw.totals.recordDays, 0, 90, "totals.recordDays"),
  };
  if (totals.doses !== totals.taken + totals.missed + totals.unresolved) {
    throw new ForecastError(400, "Medication totals do not match.");
  }
  if (!Array.isArray(raw.days) || raw.days.length !== periodDays) {
    throw new ForecastError(400, "Daily history does not match the period.");
  }
  const days = raw.days.map((value, index) => {
    if (!isRecord(value)) throw new ForecastError(400, `Invalid day ${index}.`);
    const date = text(value.date, 10, `days[${index}].date`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new ForecastError(400, `Invalid day ${index} date.`);
    }
    return {
      date,
      taken: integer(value.taken, 0, 10000, `days[${index}].taken`),
      missed: integer(value.missed, 0, 10000, `days[${index}].missed`),
      unresolved: integer(value.unresolved, 0, 10000, `days[${index}].unresolved`),
      possibleFallAlerts: integer(
        value.possibleFallAlerts,
        0,
        10000,
        `days[${index}].possibleFallAlerts`,
      ),
    };
  });
  const alertHours = integerArray(raw.alertHours, 4, "alertHours");
  if (!isRecord(raw.fallStatuses)) {
    throw new ForecastError(400, "Invalid fallStatuses.");
  }
  const fallStatuses: Record<string, number> = {};
  for (const key of ["Alert sent", "Cancelled", "Unresolved"]) {
    fallStatuses[key] = integer(raw.fallStatuses[key], 0, 100000, key);
  }
  return { elderlyId, periodDays, asOf, totals, days, alertHours, fallStatuses };
}

function parseForecast(raw: unknown): Forecast {
  if (!isRecord(raw)) {
    throw new ForecastError(502, "The AI service returned invalid data.");
  }
  const predictedCompletion = integer(raw.predictedCompletion, 0, 100, "prediction");
  let completionLower = integer(raw.completionLower, 0, 100, "lower bound");
  let completionUpper = integer(raw.completionUpper, 0, 100, "upper bound");
  if (completionLower > completionUpper) {
    [completionLower, completionUpper] = [completionUpper, completionLower];
  }
  const trend = enumValue(raw.trend, [
    "improving",
    "stable",
    "declining",
    "insufficient_data",
  ] as const, "trend");
  const possibleFallAlertLevel = enumValue(raw.possibleFallAlertLevel, [
    "low",
    "moderate",
    "elevated",
    "insufficient_data",
  ] as const, "alert level");
  if (!Array.isArray(raw.actions) || raw.actions.length < 1 || raw.actions.length > 3) {
    throw new ForecastError(502, "The AI service returned invalid actions.");
  }
  return {
    summary: text(raw.summary, 500, "summary"),
    predictedCompletion,
    completionLower,
    completionUpper,
    trend,
    possibleFallAlertLevel,
    actions: raw.actions.map((value) => text(value, 240, "action")),
    limitations: text(raw.limitations, 400, "limitations"),
  };
}

async function caregiverIsLinked(
  caregiverId: string,
  elderlyId: string,
  token: string,
  env: StatisticsEnv,
): Promise<boolean> {
  const documentId = encodeURIComponent(`${caregiverId}_${elderlyId}`);
  const endpoint =
    `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(env.FIREBASE_PROJECT_ID)}` +
    `/databases/(default)/documents/care_links/${documentId}`;
  const result = await fetch(endpoint, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!result.ok) return false;
  const document = await result.json() as {
    fields?: Record<string, { stringValue?: string }>;
  };
  return document.fields?.caregiverId?.stringValue === caregiverId &&
    document.fields?.elderlyId?.stringValue === elderlyId &&
    document.fields?.status?.stringValue === "active";
}

function safeModel(value: string | undefined): string {
  return value && /^[A-Za-z0-9._\/-]{1,120}$/.test(value)
    ? value
    : "openai/gpt-oss-20b";
}

async function sha256(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function response(value: unknown, status: number): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function identifier(value: unknown, name: string): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new ForecastError(400, `Invalid ${name}.`);
  }
  return value;
}

function integer(
  value: unknown,
  minimum: number,
  maximum: number,
  name: string,
): number {
  if (!Number.isInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new ForecastError(400, `Invalid ${name}.`);
  }
  return value as number;
}

function integerArray(value: unknown, length: number, name: string): number[] {
  if (!Array.isArray(value) || value.length !== length) {
    throw new ForecastError(400, `Invalid ${name}.`);
  }
  return value.map((item, index) => integer(item, 0, 100000, `${name}[${index}]`));
}

function text(value: unknown, maximum: number, name: string): string {
  if (typeof value !== "string" || value.trim().length < 1 || value.trim().length > maximum) {
    throw new ForecastError(400, `Invalid ${name}.`);
  }
  return value.trim();
}

function enumValue<const T extends readonly string[]>(
  value: unknown,
  allowed: T,
  name: string,
): T[number] {
  if (typeof value !== "string" || !allowed.includes(value)) {
    throw new ForecastError(502, `Gemini returned an invalid ${name}.`);
  }
  return value as T[number];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

class ForecastError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}
