export interface EmergencyLocation {
  latitude: number;
  longitude: number;
  recordedAt: number;
  accuracyMeters: number;
  source: "phone" | "watch";
  kind: "current" | "last_known";
}

export function parseEmergencyLocation(value: unknown, referenceTime: number): EmergencyLocation | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  const v = value as Record<string, unknown>;
  const { latitude, longitude, recordedAt, accuracyMeters, source, kind } = v;
  if (typeof latitude !== "number" || !Number.isFinite(latitude) || Math.abs(latitude) > 90 ||
      typeof longitude !== "number" || !Number.isFinite(longitude) || Math.abs(longitude) > 180 ||
      typeof recordedAt !== "number" || !Number.isSafeInteger(recordedAt) ||
      recordedAt < referenceTime - 24 * 60 * 60000 || recordedAt > referenceTime + 60000 ||
      typeof accuracyMeters !== "number" || !Number.isFinite(accuracyMeters) ||
      accuracyMeters < 0 || accuracyMeters > 100000 ||
      (source !== "phone" && source !== "watch") || (kind !== "current" && kind !== "last_known")) return;
  return { latitude, longitude, recordedAt, accuracyMeters, source, kind };
}

export function locationFromFirestore(value: any, referenceTime: number): EmergencyLocation | undefined {
  const fields = value?.mapValue?.fields;
  if (!fields) return;
  const numeric = (key: string) => Number(fields[key]?.doubleValue ?? fields[key]?.integerValue ?? NaN);
  return parseEmergencyLocation({
    latitude: numeric("latitude"), longitude: numeric("longitude"),
    recordedAt: numeric("recordedAt"), accuracyMeters: numeric("accuracyMeters"),
    source: fields.source?.stringValue, kind: fields.kind?.stringValue,
  }, referenceTime);
}

export function locationMapsUrl(location: EmergencyLocation): string {
  return `https://www.google.com/maps/search/?api=1&query=${location.latitude},${location.longitude}`;
}

export function locationDescription(location: EmergencyLocation): string {
  const time = new Date(location.recordedAt).toLocaleString("en-MY", { timeZone: "Asia/Kuala_Lumpur" });
  return `${location.kind === "last_known" ? "Last known location" : "Recorded location"} from the ${location.source}, ${time} (Malaysia time), accuracy about ${Math.round(location.accuracyMeters)} m.`;
}
