-- Review-only artifact. Do not run without explicit approval.
-- Additive column grants only; existing payment_owner_read RLS remains row boundary.
BEGIN;

GRANT SELECT (id, booking_id, status, method, amount, paid_at, created_at)
ON TABLE public.payments
TO authenticated;

COMMIT;
