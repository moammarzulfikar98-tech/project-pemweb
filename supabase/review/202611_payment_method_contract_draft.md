# REVIEW-ONLY DRAFT — server-side demo payment method

Status: NOT FOR EXECUTION. Design artifact only. No production SQL run.

## Goal

Persist selected UI method before payment trigger:

```text
qris            -> qris_demo
virtual_account -> transfer_demo
cash            -> cash_demo
```

`confirm_my_demo_payment` remains unchanged. Its method mismatch guard stays mandatory.

## Current collision

Existing trigger creates `qris_demo` for every inserted booking. Existing create RPCs do not receive payment method. Adding only a new RPC overload is insufficient unless booking stores method before `AFTER INSERT` trigger runs.

## Schema change

Add `public.bookings.payment_method public.payment_method` with:

- `NOT NULL`
- default `qris_demo` only for backward-compatible legacy callers and direct inserts
- `CHECK (payment_method IN ('qris_demo','transfer_demo','cash_demo'))`

The default is compatibility behavior, not the new UI path. New RPCs always write an explicit value.

Preflight must abort when any of these are false:

- `public.bookings` exists;
- `public.bookings.payment_method` is absent or already exactly `public.payment_method NOT NULL`;
- enum labels `qris_demo`, `transfer_demo`, `cash_demo` exist;
- existing `bookings_create_unpaid_payment` is the expected trigger;
- no unexpected trigger writes `public.payments` on booking insert;
- `payments.booking_id` remains single-column unique;
- `payments.method` remains `public.payment_method NOT NULL`.

Do not silently overwrite a differently shaped column, trigger, or constraint. Abort with a collision error.

## Trigger replacement — atomic transaction

Replace `public.create_unpaid_payment_for_booking()` in same migration transaction:

```sql
INSERT INTO public.payments (booking_id, provider, method, amount, status)
VALUES (
  NEW.id,
  'demo',
  NEW.payment_method,
  NEW.total_amount,
  'unpaid'
)
ON CONFLICT (booking_id) DO NOTHING;
```

The trigger must not fallback to `qris_demo`. `NEW.payment_method` is `NOT NULL`, so missing explicit values fail before trigger execution.

Keep:

- `AFTER INSERT ON public.bookings`;
- `ON CONFLICT (booking_id) DO NOTHING`;
- `unpaid` initial status;
- no backfill;
- no update to existing payments.

## Input contract

New overloads add final parameter:

```text
p_payment_method text
```

Accepted external values only:

```text
qris
virtual_account
cash
```

Normalize with `lower(btrim(...))`. Reject NULL, blank, and every other value before any customer, elder, booking, or payment write.

Map once in function-local variable:

```text
qris            -> qris_demo
virtual_account -> transfer_demo
cash            -> cash_demo
```

Do not accept internal enum names from UI. Do not map `virtual_account` to QRIS.

## Customer flow

Keep old signature unchanged as compatibility wrapper:

```text
create_customer_booking(old 21-argument signature)
  -> call new overload with 'qris'
```

Create new overload with old arguments plus `p_payment_method text`.

New overload body must preserve existing validation, pricing, ownership, RLS assumptions, and idempotency locking. Required changes only:

1. Validate/map `p_payment_method` before writes.
2. Add canonical mapped method to `v_canonical_payload`.
3. Keep the method in `request_hash`; same idempotency key with another method must raise `Idempotency key payload conflict`.
4. Insert explicit `payment_method = v_payment_method` in `public.bookings` before `AFTER INSERT` trigger fires.
5. Existing-idempotency return must return existing booking without creating another booking/payment.
6. Existing booking with same key but method mismatch must fail through request-hash conflict, not silently reuse.

Keep grants/revokes for both exact signatures. Do not grant the new overload to anon. Existing customer authenticated grant remains.

## Anonymous flow

Keep old signature unchanged as compatibility wrapper:

```text
create_anonymous_booking(old signature)
  -> call new overload with 'qris'
```

Create new overload with final `p_payment_method text` and apply same validation, canonical payload, idempotency, explicit booking method, and atomic trigger behavior.

Anonymous payment confirmation decision:

- Anonymous booking can create `unpaid` payment with `qris_demo`, `transfer_demo`, or `cash_demo`.
- Anonymous flow must not call `confirm_my_demo_payment`.
- `confirm_my_demo_payment` requires authenticated customer ownership through `auth.uid()`.
- Cash never auto-transitions to `paid_demo`.
- No claim that anonymous payment confirmation is available.

Grant new anonymous booking overload only to the existing anonymous role used by current flow. Do not grant customer payment RPC to anon.

## Function collision guard

Before creating overloads, assert:

```text
old customer signature exists exactly once;
old anonymous signature exists exactly once;
new signatures do not exist;
```

After creation, assert exact `pg_proc.oid` signatures exist and old signatures still exist. Abort if an unexpected overload is found.

Do not `DROP FUNCTION` old signatures. Use `CREATE OR REPLACE` only for old-signature wrappers after new overloads exist, or equivalent guarded replacement. Preserve existing ACLs and verify them after replacement.

## Payment confirmation invariant

`public.confirm_my_demo_payment(uuid, public.payment_method)` remains unchanged:

- ownership check stays;
- provider must remain `demo`;
- payment method must equal requested method;
- amount must equal server booking total;
- transition stays `unpaid -> paid_demo` only;
- retry remains idempotent;
- no direct frontend UPDATE;
- no `paid` transition from customer flow.

## Required review tests before approval

Read-only/static:

- `pg_get_functiondef` confirms old/new customer and anonymous bodies;
- both canonical payloads contain mapped payment method;
- booking insert sets `payment_method` before trigger;
- trigger uses `NEW.payment_method`, never a literal `qris_demo`;
- old signatures remain callable;
- ACLs match intended roles;
- `confirm_my_demo_payment` body is unchanged.

Runtime after explicit migration approval:

1. Customer QRIS: new booking payment `qris_demo`, initial `unpaid`.
2. Customer VA: new booking payment `transfer_demo`, initial `unpaid`.
3. Customer cash: `cash_demo`, no automatic `paid_demo`.
4. Same idempotency key + same method: one booking, one payment.
5. Same idempotency key + different method: conflict, no second booking/payment.
6. Anonymous QRIS/VA/cash creation: correct method, still `unpaid`.
7. Anonymous cannot call customer confirmation RPC.
8. Customer confirm method mismatch: rejected.
9. Customer correct method: `paid_demo`.
10. Existing bookings/payments unchanged.

## Decision

VA remains disabled in frontend. This draft requires review and explicit approval before conversion into executable migration and production execution.
