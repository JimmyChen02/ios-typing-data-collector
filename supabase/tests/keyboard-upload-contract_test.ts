import {
  assertEquals,
  assertThrows,
} from "jsr:@std/assert@1";
import {
  eventRow,
  MAX_BATCH_EVENTS,
  validateEnvelope,
} from "../functions/_shared/keyboard-upload-contract.ts";

const event = {
  id: "00000000-0000-4000-8000-000000000001",
  schemaVersion: 6,
  timestamp: "2026-07-29T22:00:00Z",
  sessionID: "00000000-0000-4000-8000-000000000002",
  kind: "insert",
  key: "a",
  rawContext: "full text is intentionally retained",
};

Deno.test("validates a complete upload envelope", () => {
  const envelope = validateEnvelope({
    batchId: "00000000-0000-4000-8000-000000000003",
    installationId: "00000000-0000-4000-8000-000000000004",
    consentVersion: 1,
    events: [event],
  });

  assertEquals(envelope.events.length, 1);
});

Deno.test("rejects malformed and oversized batches", () => {
  assertThrows(() => validateEnvelope({ events: [] }));
  assertThrows(() =>
    validateEnvelope({
      batchId: "00000000-0000-4000-8000-000000000003",
      installationId: "00000000-0000-4000-8000-000000000004",
      consentVersion: 1,
      events: Array.from({ length: MAX_BATCH_EVENTS + 1 }, () => event),
    })
  );
});

Deno.test("rejects duplicate event ids within a batch", () => {
  assertThrows(() =>
    validateEnvelope({
      batchId: "00000000-0000-4000-8000-000000000003",
      installationId: "00000000-0000-4000-8000-000000000004",
      consentVersion: 1,
      events: [event, event],
    })
  );
});

Deno.test("maps validated event metadata and preserves payload", () => {
  const row = eventRow(
    event,
    "00000000-0000-4000-8000-000000000005",
    "00000000-0000-4000-8000-000000000006",
  );
  assertEquals(row.event_id, event.id);
  assertEquals(row.session_id, event.sessionID);
  assertEquals(row.payload.rawContext, event.rawContext);
});
