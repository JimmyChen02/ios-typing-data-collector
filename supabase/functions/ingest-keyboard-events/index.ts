import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  eventRow,
  MAX_BODY_BYTES,
  validateEnvelope,
} from "../_shared/keyboard-upload-contract.ts";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "Method not allowed." }, 405);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) {
    return json({ error: "Request body is too large." }, 413);
  }

  const authorization = request.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) {
    return json({ error: "A bearer token is required." }, 401);
  }

  const supabaseURL = requiredEnvironment("SUPABASE_URL");
  const anonKey = requiredEnvironment("SUPABASE_ANON_KEY");
  const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
  const userClient = createClient(supabaseURL, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const {
    data: { user },
    error: userError,
  } = await userClient.auth.getUser();
  if (userError || !user) return json({ error: "Invalid access token." }, 401);
  if (!user.is_anonymous) {
    return json({ error: "This endpoint accepts anonymous study users only." }, 403);
  }

  let envelope;
  try {
    const bodyText = await request.text();
    if (new TextEncoder().encode(bodyText).byteLength > MAX_BODY_BYTES) {
      return json({ error: "Request body is too large." }, 413);
    }
    envelope = validateEnvelope(JSON.parse(bodyText));
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid request.";
    return json({ error: message }, 400);
  }

  const admin = createClient(supabaseURL, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: existing, error: lookupError } = await admin
    .from("keyboard_installations")
    .select("id, auth_user_id")
    .eq("app_installation_id", envelope.installationId)
    .maybeSingle();
  if (lookupError) return serverError(lookupError);
  if (existing && existing.auth_user_id !== user.id) {
    return json({ error: "Installation belongs to another user." }, 403);
  }

  let installation = existing;
  if (!installation) {
    const { data, error } = await admin
      .from("keyboard_installations")
      .insert({
        auth_user_id: user.id,
        app_installation_id: envelope.installationId,
        consent_version: envelope.consentVersion,
      })
      .select("id, auth_user_id")
      .single();
    if (error) return serverError(error);
    installation = data;
  } else {
    const { error } = await admin
      .from("keyboard_installations")
      .update({
        consent_version: envelope.consentVersion,
        last_seen_at: new Date().toISOString(),
      })
      .eq("id", installation.id)
      .eq("auth_user_id", user.id);
    if (error) return serverError(error);
  }

  const rows = envelope.events.map((event) =>
    eventRow(event, installation.id, user.id)
  );
  const { error: eventError } = await admin
    .from("keyboard_events")
    .upsert(rows, { onConflict: "event_id", ignoreDuplicates: true });
  if (eventError) return serverError(eventError);

  const acknowledgedEventIDs = envelope.events.map((event) => String(event.id));
  const { error: receiptError } = await admin
    .from("keyboard_upload_receipts")
    .upsert({
      batch_id: envelope.batchId,
      installation_id: installation.id,
      auth_user_id: user.id,
      submitted_count: envelope.events.length,
      acknowledged_count: acknowledgedEventIDs.length,
    }, { onConflict: "batch_id", ignoreDuplicates: true });
  if (receiptError) return serverError(receiptError);

  return json({
    batchId: envelope.batchId,
    acknowledgedEventIDs,
    serverTime: new Date().toISOString(),
  });
});

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing server environment variable ${name}.`);
  return value;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function serverError(error: { message: string }): Response {
  console.error(error.message);
  return json({ error: "The upload could not be stored." }, 500);
}
