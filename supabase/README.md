# Supabase keyboard-event backend

This backend accepts schema-v6 `KeyboardResearchEvent` batches from anonymous,
consented app installations. Participants do not create accounts. Direct table
access is denied to app users; the Edge Function validates their JWT and writes
with the server-only service role.

The selected payload is the **full event schema**. It can include surrounding
context, inserted/deleted/replacement text, candidate words, emoji, and key
labels. Do not collect real participant data until the consent language, IRB
protocol, Supabase region, retention period, and researcher access list have
been approved.

## Create and deploy

1. Create a Supabase project in the approved region. The free plan is suitable
   for development but can pause after inactivity and has no production SLA.
2. In Authentication settings, enable anonymous sign-ins.
3. Install the Supabase CLI and authenticate:

   ```sh
   brew install supabase/tap/supabase
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   ```

4. Apply the database migration and deploy the function:

   ```sh
   supabase db push
   supabase functions deploy ingest-keyboard-events
   ```

   Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
   `SUPABASE_SERVICE_ROLE_KEY` to the hosted function. Never put the service-role
   key in Xcode, source control, or the app.
5. Put the project URL and publishable/anonymous key in both target
   configurations as described in `docs/SYSTEM_KEYBOARD.md`. These values
   identify the public project; authorization still comes from each
   installation's anonymous JWT.

## Researcher access and export

Require MFA on researcher Supabase accounts and grant project access only to
approved study staff. The app roles have no direct table privileges. A
researcher can export full JSON payloads in chronological order with:

```sql
select
  event_id,
  event_timestamp,
  schema_version,
  event_kind,
  payload
from public.keyboard_events
order by event_timestamp, event_id;
```

Use the dashboard CSV export for a small dataset or `psql`/the Supabase CLI for
repeatable exports. Treat exports as sensitive research data.

## Integrity and retention

- `keyboard_events.event_id` is the idempotency key. Retried batches do not
  create duplicate events.
- `keyboard_upload_receipts` provides batch-level audit records.
- The iPhone retains encrypted source events until its normal 30-day purge and
  separately records server acknowledgements.
- Deleting local logs does not delete server records. Server deletion must be
  performed by an authorized researcher according to the approved retention
  protocol.

Before production collection, configure database backups, budget/usage alerts,
an incident contact, and a scheduled server-retention job matching the protocol.

## Tests

The pure request-contract tests require Deno:

```sh
deno test supabase/tests
```

End-to-end authorization, ownership, RLS, and duplicate-ingest tests require a
linked/local Supabase project and should be run before production deployment.
