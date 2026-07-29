# Supabase keyboard upload

## Attempt
- Added a Supabase migration, JWT-protected Edge Function, request-contract and
  optional integration tests, and researcher deployment/export instructions.
- Added a shared iOS uploader for the encrypted keyboard ledger with anonymous
  auth, durable acknowledgements, UUID deduplication, 50-event batches,
  activity-based 15-minute scheduling, and bounded retry backoff.
- Added explicit full-schema consent, manual upload, status counts, app
  foreground retries, and extension-active retries.

## Problems encountered
- The first iOS test build failed because async actor calls were nested in
  XCTest assertion autoclosures. The calls were evaluated into local values
  before assertions.
- Swift warned about retroactive `Sendable` conformance and `NSLock` calls from
  async test code. `EncryptedEventLedger` was marked sendable in its defining
  file, the date closure was made explicitly sendable, and test lock access was
  moved into a synchronous helper.
- CoreSimulator repeatedly shut down after test bundle compilation, causing
  three test runs to stall before XCTest execution. The processes were stopped.
- Deno is not installed, so Edge Function tests could not execute locally.

## Outcome
- Generic iOS Simulator build succeeded.
- `build-for-testing` succeeded for the app, extension, and test bundle.
- Runtime XCTest execution and Supabase smoke/integration testing remain
  environment-blocked; they require a functioning simulator and configured
  Supabase project credentials.
