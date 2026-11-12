-- Grant caregiver read access to payment status only through existing RLS policy.
-- Existing payment_owner_read policy remains the row-level ownership boundary.
BEGIN;

GRANT SELECT (status) ON TABLE public.payments TO authenticated;

COMMIT;
