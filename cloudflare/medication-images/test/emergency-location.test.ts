import test from "node:test";
import assert from "node:assert/strict";
import { parseEmergencyLocation, locationFromFirestore, locationMapsUrl } from "../src/emergency_location.ts";
const now = Date.now();
const valid = { latitude: 3.139, longitude: 101.6869, recordedAt: now - 600000,
  accuracyMeters: 50, source: "phone", kind: "last_known" };
test("valid location is optional and cannot inject a Maps destination", () => {
  assert.equal(parseEmergencyLocation(undefined, now), undefined);
  assert.equal(locationFromFirestore(undefined, now), undefined);
  const location = parseEmergencyLocation({ ...valid, url: "https://attacker.test" }, now);
  assert.ok(location);
  assert.equal(locationMapsUrl(location), "https://www.google.com/maps/search/?api=1&query=3.139,101.6869");
});
test("rejects invalid, stale, future, and non-finite location input", () => {
  for (const change of [{latitude:91}, {longitude:-181}, {latitude:NaN}, {longitude:Infinity},
    {recordedAt:now - 86400001}, {recordedAt:now + 60001}, {recordedAt:now - 0.5},
    {accuracyMeters:-1}, {accuracyMeters:100001}, {source:"other"}, {kind:"live"}, {latitude:"3.139"}]) {
    assert.equal(parseEmergencyLocation({...valid, ...change}, now), undefined, JSON.stringify(change));
  }
});
