export const MAX_BATCH_EVENTS = 100;
export const MAX_BODY_BYTES = 1_000_000;

export type UploadEnvelope = {
  batchId: string;
  installationId: string;
  consentVersion: number;
  events: Record<string, unknown>[];
};

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateEnvelope(value: unknown): UploadEnvelope {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Request body must be a JSON object.");
  }

  const envelope = value as Partial<UploadEnvelope>;
  if (!isUUID(envelope.batchId)) throw new Error("batchId must be a UUID.");
  if (!isUUID(envelope.installationId)) {
    throw new Error("installationId must be a UUID.");
  }
  if (
    !Number.isInteger(envelope.consentVersion) ||
    Number(envelope.consentVersion) <= 0
  ) {
    throw new Error("consentVersion must be a positive integer.");
  }
  if (!Array.isArray(envelope.events) || envelope.events.length === 0) {
    throw new Error("events must be a non-empty array.");
  }
  if (envelope.events.length > MAX_BATCH_EVENTS) {
    throw new Error(`events may contain at most ${MAX_BATCH_EVENTS} records.`);
  }

  const seen = new Set<string>();
  for (const event of envelope.events) {
    validateEvent(event);
    const id = String(event.id).toLowerCase();
    if (seen.has(id)) throw new Error(`Duplicate event id in batch: ${id}`);
    seen.add(id);
  }

  return envelope as UploadEnvelope;
}

export function eventRow(
  event: Record<string, unknown>,
  installationDatabaseID: string,
  authUserID: string,
) {
  return {
    event_id: event.id,
    installation_id: installationDatabaseID,
    auth_user_id: authUserID,
    session_id: event.sessionID ?? null,
    event_timestamp: event.timestamp,
    schema_version: event.schemaVersion,
    event_kind: event.kind,
    payload: event,
  };
}

function validateEvent(value: unknown): asserts value is Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Each event must be a JSON object.");
  }
  const event = value as Record<string, unknown>;
  if (!isUUID(event.id)) throw new Error("Each event id must be a UUID.");
  if (
    !Number.isInteger(event.schemaVersion) ||
    Number(event.schemaVersion) <= 0
  ) {
    throw new Error(`Event ${event.id} has an invalid schemaVersion.`);
  }
  if (
    typeof event.kind !== "string" ||
    event.kind.length === 0 ||
    event.kind.length > 80
  ) {
    throw new Error(`Event ${event.id} has an invalid kind.`);
  }
  if (
    typeof event.timestamp !== "string" ||
    Number.isNaN(Date.parse(event.timestamp))
  ) {
    throw new Error(`Event ${event.id} has an invalid timestamp.`);
  }
  if (event.sessionID != null && !isUUID(event.sessionID)) {
    throw new Error(`Event ${event.id} has an invalid sessionID.`);
  }
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}
