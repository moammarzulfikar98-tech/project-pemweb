-- ============================================================================
-- MIGRATION: 20261107_000004_customer_auth_existing_accounts.sql
-- PURPOSE:
--   Repair profiles and customer roles for Auth users created before
--   20261104_000003_customer_auth_trigger.sql was installed.
--
-- SAFETY:
--   - REVIEW/DESIGN ONLY. Do not execute without separate approval.
--   - Inserts only missing profiles/roles; never overwrites or deletes existing
--     profiles, roles, customers, or bookings.
--   - Ignores anonymous users.
--   - Never trusts raw_user_meta_data.role.
--   - Never grants customer to an account marked/provisioned as caregiver/admin
--     or linked to a caregiver row.
--   - Does not create public.customers: emergency contact fields are required;
--     create_customer_booking creates/upserts that row atomically with contact data.
-- ============================================================================

BEGIN;

DO $preflight_existing_customer_accounts$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(x.object_name, ', ' ORDER BY x.object_name)
    INTO v_missing
  FROM (VALUES
    ('auth.users'),
    ('public.profiles'),
    ('public.user_roles'),
    ('public.customers'),
    ('public.caregivers')
  ) AS x(object_name)
  WHERE to_regclass(x.object_name) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'customer account repair preflight failed; missing relation(s): %', v_missing;
  END IF;

  IF to_regprocedure('public.handle_new_customer_user()') IS NULL THEN
    RAISE EXCEPTION 'customer account repair preflight failed; 000003 trigger function is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'auth.users'::regclass
      AND tgname = 'on_auth_user_created'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'customer account repair preflight failed; on_auth_user_created trigger is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typnamespace = 'public'::regnamespace
      AND t.typname = 'app_role'
      AND e.enumlabel = 'customer'
  ) THEN
    RAISE EXCEPTION 'customer account repair preflight failed; app_role.customer is missing';
  END IF;

  SELECT string_agg(x.column_name, ', ' ORDER BY x.column_name)
    INTO v_missing
  FROM (VALUES
    ('id'),
    ('email'),
    ('is_anonymous'),
    ('raw_app_meta_data'),
    ('raw_user_meta_data')
  ) AS x(column_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_attribute a
    WHERE a.attrelid = 'auth.users'::regclass
      AND a.attname = x.column_name
      AND a.attnum > 0
      AND NOT a.attisdropped
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'customer account repair preflight failed; auth.users column(s) missing: %', v_missing;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM auth.users AS u
    WHERE COALESCE(u.is_anonymous, false) IS FALSE
      AND NULLIF(btrim(COALESCE(u.raw_app_meta_data ->> 'temanlansia_provisioned_role', '')), '') IS NOT NULL
      AND NULLIF(btrim(COALESCE(u.raw_app_meta_data ->> 'temanlansia_provisioned_role', '')), '')
          NOT IN ('customer', 'caregiver', 'admin')
  ) THEN
    RAISE EXCEPTION 'customer account repair preflight failed; invalid trusted provisioning role exists';
  END IF;
END
$preflight_existing_customer_accounts$;

-- Fill only missing profile rows. Existing identity data remains untouched.
INSERT INTO public.profiles (id, full_name, phone)
SELECT
  u.id,
  COALESCE(
    NULLIF(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
    NULLIF(btrim(split_part(COALESCE(u.email, ''), '@', 1)), ''),
    'Customer'
  ),
  NULLIF(btrim(u.raw_user_meta_data ->> 'phone'), '')
FROM auth.users AS u
WHERE COALESCE(u.is_anonymous, false) IS FALSE
  AND COALESCE(u.raw_app_meta_data ->> 'provider', '') <> 'anonymous'
ON CONFLICT (id) DO NOTHING;

-- Add the fixed customer role only for accounts without a trusted staff signal.
-- A customer row is deferred to create_customer_booking, which has the
-- emergency-contact values required by public.customers.
INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'customer'::public.app_role
FROM auth.users AS u
WHERE COALESCE(u.is_anonymous, false) IS FALSE
  AND COALESCE(u.raw_app_meta_data ->> 'provider', '') <> 'anonymous'
  AND COALESCE(NULLIF(btrim(u.raw_app_meta_data ->> 'temanlansia_provisioned_role'), ''), '')
      NOT IN ('caregiver', 'admin')
  AND NOT EXISTS (
    SELECT 1
    FROM public.user_roles AS existing_role
    WHERE existing_role.user_id = u.id
      AND existing_role.role IN ('caregiver'::public.app_role, 'admin'::public.app_role)
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.caregivers AS caregiver
    WHERE caregiver.user_id = u.id
  )
ON CONFLICT (user_id, role) DO NOTHING;

COMMIT;
