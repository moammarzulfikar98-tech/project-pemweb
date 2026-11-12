# Payment-method draft verification

Date: 2026-11-09
Artifact:
`supabase/review/202611_payment_method_contract_draft.sql`

## Result

Status: NOT READY

## Evidence

Local parser/runtime probe:

```text
command -v psql: unavailable
command -v postgres: unavailable
command -v docker: unavailable
command -v initdb: unavailable
command -v pg_tmp: unavailable
sqlglot: unavailable
pglast: unavailable
psycopg: unavailable
```

Therefore:

- PostgreSQL parse/compile: NOT TESTED
- Disposable staging migration: NOT RUN
- Customer insert/retry: NOT TESTED
- Anonymous insert/retry: NOT TESTED
- qris/VA/cash mapping: NOT TESTED
- trigger order: NOT TESTED
- ACL behavior: NOT TESTED
- rollback behavior: NOT TESTED
- existing-row preservation: NOT TESTED

## Static review findings

The draft contains structural guards for:

- enum and table presence;
- old RPC signatures;
- trigger function and trigger identity;
- SECURITY DEFINER and privileges;
- `bookings.payment_method` addition;
- explicit method mapping;
- idempotency payload inclusion;
- `NEW.payment_method` trigger use;
- old/new RPC ACLs;
- postflight signatures.

Static checks are not PostgreSQL evidence.

## Blocking design issue found

The draft uses a nullable column plus:

```sql
ALTER TABLE public.bookings
  ALTER COLUMN payment_method
  SET DEFAULT 'qris_demo'::public.payment_method;
```

This avoids a NOT NULL migration failure, but does not prove existing rows remain semantically unchanged. PostgreSQL version/storage behavior must be verified in disposable staging. Existing rows with NULL can be observed through a default as `qris_demo` on some versions, which conflicts with a strict "existing rows unchanged" acceptance criterion.

Safer staged design requires separate approval:

1. Add nullable column with no default.
2. New RPC wrappers explicitly write `qris_demo`.
3. New RPC overloads explicitly write mapped method.
4. Trigger rejects NULL and reads `NEW.payment_method`.
5. Prove no existing booking is updated.
6. Add default only if compatibility caller behavior is confirmed and existing-row semantics are accepted.
7. Add NOT NULL only after a reviewed treatment for pre-existing NULL rows; no automatic backfill allowed.

## Decision

Do not execute SQL. Do not enable VA. Do not claim compile, rollback, or runtime success.

Required next gate: approved disposable PostgreSQL environment, then parser/migration/verifier and role-isolated runtime tests.
