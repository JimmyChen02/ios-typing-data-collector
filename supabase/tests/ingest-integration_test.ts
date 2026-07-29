import { assertEquals } from "jsr:@std/assert@1";

const supabaseURL = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const integrationOptions = { ignore: !supabaseURL || !anonKey };

async function anonymousToken(): Promise<string> {
  const response = await fetch(`${supabaseURL}/auth/v1/signup`, {
    method: "POST",
    headers: { apikey: anonKey!, "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) {
    throw new Error(`Anonymous sign-in failed: ${JSON.stringify(body)}`);
  }
  return body.access_token;
}

function upload(token: string | null, body: unknown): Promise<Response> {
  const headers: Record<string, string> = {
    apikey: anonKey!,
    "content-type": "application/json",
  };
  if (token) headers.authorization = `Bearer ${token}`;
  return fetch(`${supabaseURL}/functions/v1/ingest-keyboard-events`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function validEnvelope(installationId: string) {
  return {
    batchId: crypto.randomUUID(),
    installationId,
    consentVersion: 1,
    events: [{
      id: crypto.randomUUID(),
      schemaVersion: 6,
      timestamp: new Date().toISOString(),
      sessionID: crypto.randomUUID(),
      kind: "insert",
      key: "a",
      rawContext: "integration test",
    }],
  };
}

Deno.test({
  name: "ingest rejects missing and invalid JWTs",
  ...integrationOptions,
  fn: async () => {
    assertEquals((await upload(null, {})).status, 401);
    assertEquals((await upload("not-a-jwt", {})).status, 401);
  },
});

Deno.test({
  name: "ingest rejects malformed authenticated batches",
  ...integrationOptions,
  fn: async () => {
    const token = await anonymousToken();
    assertEquals((await upload(token, { events: [] })).status, 400);
  },
});

Deno.test({
  name: "ingest acknowledges duplicate-safe resends",
  ...integrationOptions,
  fn: async () => {
    const token = await anonymousToken();
    const envelope = validEnvelope(crypto.randomUUID());
    const first = await upload(token, envelope);
    assertEquals(first.status, 200);
    const second = await upload(token, { ...envelope, batchId: crypto.randomUUID() });
    assertEquals(second.status, 200);
    const body = await second.json();
    assertEquals(body.acknowledgedEventIDs, [envelope.events[0].id]);
  },
});

Deno.test({
  name: "ingest prevents installation takeover by another user",
  ...integrationOptions,
  fn: async () => {
    const firstToken = await anonymousToken();
    const secondToken = await anonymousToken();
    const installationID = crypto.randomUUID();
    assertEquals(
      (await upload(firstToken, validEnvelope(installationID))).status,
      200,
    );
    assertEquals(
      (await upload(secondToken, validEnvelope(installationID))).status,
      403,
    );
  },
});
