-- DESIGN / MIGRATION DRAFT ONLY: Tahap A
-- NOT EXECUTED. Requires explicit Approval A.
-- Scope: add customer identity column only.
-- No backfill, RPC, RLS, GRANT, policy, caregiver, or frontend changes.

BEGIN;

ALTER TABLE public.customers
  ADD COLUMN customer_name text;

COMMIT;

-- Rollback is intentionally manual and disabled by default.
-- Never drop this column after data is written without separate approval.
-- ALTER TABLE public.customers
--   DROP COLUMN customer_name;
