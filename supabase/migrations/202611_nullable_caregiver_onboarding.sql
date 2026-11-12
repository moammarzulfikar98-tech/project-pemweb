-- ============================================================================
-- MIGRATION: 202611_nullable_caregiver_onboarding.sql
-- PURPOSE:
--   Allow creating new caregiver records without dummy/placeholder data
--   for fields that are managed independently by the caregiver (city, area,
--   gender, price_per_shift).
-- SAFETY & INTEGRITY:
--   - Seed caregivers 1-100 remain intact with complete data.
--   - Booking guard on customer portal prevents booking if operational fields
--     or price_per_shift are null.
-- STATUS:
--   REVIEW ARTIFACT ONLY. Do NOT execute without explicit user approval.
-- ============================================================================

BEGIN;

ALTER TABLE public.caregivers
  ALTER COLUMN city DROP NOT NULL,
  ALTER COLUMN area DROP NOT NULL,
  ALTER COLUMN gender DROP NOT NULL,
  ALTER COLUMN price_per_shift DROP NOT NULL;

COMMIT;
