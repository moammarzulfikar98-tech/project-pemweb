-- REVIEW ARTIFACT ONLY. Do not execute without separate approval.
-- Creates public.customers for future public customer signups.
-- Existing profiles/user_roles trigger remains; this function is invoked by
-- existing on_auth_user_created_z_customer_role after profile provisioning.
BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('public.provision_new_customer_relation()') IS NOT NULL THEN
    RAISE EXCEPTION 'customer relation preflight failed; migration function already exists';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'auth.users'::regclass
      AND tgname = 'on_auth_user_created_zz_customer_relation'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'customer relation preflight failed; migration trigger already exists';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.customers'::regclass
      AND confrelid = 'public.profiles'::regclass
      AND contype = 'f'
      AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.customers'::regclass AND attname = 'id')]::smallint[]
      AND confkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.profiles'::regclass AND attname = 'id')]::smallint[]
  ) THEN
    RAISE EXCEPTION 'customer relation preflight failed; customers.id -> profiles.id FK missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.customers'::regclass
      AND attname IN ('customer_name', 'emergency_contact_name', 'emergency_contact_phone')
    GROUP BY attrelid
    HAVING count(*) = 3
  ) OR EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.customers'::regclass
      AND attname IN ('emergency_contact_name', 'emergency_contact_phone')
      AND attnotnull IS FALSE
  ) THEN
    RAISE EXCEPTION 'customer relation preflight failed; required customer columns missing or emergency contact nullability changed';
  END IF;
END
$preflight$;

CREATE FUNCTION public.provision_new_customer_relation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_has_customer boolean;
  v_has_privileged boolean;
  v_name text;
  v_emergency_name text;
  v_emergency_phone text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = NEW.id AND role = 'customer'::public.app_role
  ), EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = NEW.id AND role IN ('caregiver'::public.app_role, 'admin'::public.app_role)
  ) INTO v_has_customer, v_has_privileged;
  IF NOT v_has_customer OR v_has_privileged THEN RETURN NEW; END IF;

  v_name := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data ->> 'full_name', '')), '');
  v_emergency_name := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data ->> 'emergency_contact_name', '')), '');
  v_emergency_phone := NULLIF(btrim(COALESCE(NEW.raw_user_meta_data ->> 'emergency_contact_phone', '')), '');
  IF v_name IS NULL OR v_emergency_name IS NULL OR v_emergency_phone IS NULL THEN
    RAISE EXCEPTION 'customer registration requires full name and emergency contact';
  END IF;

  INSERT INTO public.customers (id, customer_name, emergency_contact_name, emergency_contact_phone)
  VALUES (NEW.id, v_name, v_emergency_name, v_emergency_phone)
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.provision_new_customer_relation() FROM PUBLIC;

CREATE TRIGGER on_auth_user_created_zz_customer_relation
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.provision_new_customer_relation();

COMMIT;

-- Manual preflight/runtime required before deployment:
-- 1. Verify customer columns permit fallback phone semantics.
-- 2. Test public signup with email confirmation enabled.
-- 3. Test duplicate signup/retry and confirm one profile, role, customer row.
-- 4. Test caregiver/admin trusted provisioning does not create customers.
-- 5. Backfill missing existing customer rows only with separately approved
--    customer contact values; this artifact does not backfill existing data.
