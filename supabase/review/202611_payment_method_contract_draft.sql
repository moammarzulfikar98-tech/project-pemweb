-- REVIEW-ONLY DRAFT. DO NOT EXECUTE IN PRODUCTION.
-- Requires explicit approval, staging rehearsal, and rollback plan.
-- Atomic: any preflight/DDL/function error aborts whole transaction.
BEGIN;

DO $$
DECLARE r record; fn oid; trig record;
BEGIN
  IF to_regclass('public.bookings') IS NULL OR to_regclass('public.payments') IS NULL THEN RAISE EXCEPTION 'preflight: required tables missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typname='payment_method') THEN RAISE EXCEPTION 'preflight: payment_method enum missing'; END IF;
  FOR r IN SELECT unnest(ARRAY['qris_demo','transfer_demo','cash_demo']) label LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typname='payment_method' AND e.enumlabel=r.label) THEN RAISE EXCEPTION 'preflight: enum label missing: %', r.label; END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid='public.payments'::regclass AND a.attname='booking_id' AND a.atttypid='uuid'::regtype AND a.attnotnull) THEN RAISE EXCEPTION 'preflight: payments.booking_id mismatch'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid='public.payments'::regclass AND a.attname='method' AND a.atttypid='public.payment_method'::regtype AND a.attnotnull) THEN RAISE EXCEPTION 'preflight: payments.method mismatch'; END IF;
  IF to_regprocedure('public.create_customer_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz)') IS NULL THEN RAISE EXCEPTION 'preflight: old customer signature missing'; END IF;
  IF to_regprocedure('public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz)') IS NULL THEN RAISE EXCEPTION 'preflight: old anonymous signature missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid='public.create_unpaid_payment_for_booking()'::regprocedure AND prosecdef) THEN RAISE EXCEPTION 'preflight: payment trigger function missing or not SECURITY DEFINER'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.bookings'::regclass AND tgname='bookings_create_unpaid_payment' AND NOT tgisinternal AND tgfoid='public.create_unpaid_payment_for_booking()'::regprocedure) THEN RAISE EXCEPTION 'preflight: expected payment trigger/function ownership mismatch'; END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.bookings'::regclass AND tgname='bookings_create_unpaid_payment' AND NOT tgisinternal AND NOT tgenabled='O') THEN RAISE EXCEPTION 'preflight: payment trigger disabled'; END IF;
  IF NOT has_table_privilege(current_user, 'public.bookings', 'ALTER') THEN RAISE EXCEPTION 'preflight: current role cannot alter bookings'; END IF;
  IF NOT has_function_privilege(current_user, 'public.create_unpaid_payment_for_booking()', 'EXECUTE') THEN RAISE EXCEPTION 'preflight: current role lacks trigger function privilege'; END IF;
END $$;

-- Nullable, no default. Existing rows remain NULL and are never backfilled.
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS payment_method public.payment_method;
ALTER TABLE public.bookings ALTER COLUMN payment_method DROP DEFAULT;

-- Legacy wrappers write qris_demo explicitly; no schema default is used.
CREATE OR REPLACE FUNCTION public.create_unpaid_payment_for_booking()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.payment_method IS NULL THEN RAISE EXCEPTION 'booking payment_method is required'; END IF;
  INSERT INTO public.payments (booking_id, provider, method, amount, status)
  VALUES (NEW.id, 'demo', NEW.payment_method, NEW.total_amount, 'unpaid'::public.payment_status)
  ON CONFLICT (booking_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_customer_booking(
  p_idempotency_key uuid,
  p_caregiver_id uuid,
  p_customer_name text,
  p_emergency_contact_name text,
  p_emergency_contact_phone text,
  p_elder_name text,
  p_elder_age integer,
  p_elder_gender text,
  p_elder_conditions jsonb,
  p_elder_allergies text,
  p_elder_mobility text,
  p_elder_medical_notes text,
  p_address_line text,
  p_city text,
  p_province text,
  p_postal_code text,
  p_latitude numeric,
  p_longitude numeric,
  p_access_notes text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_payment_method text
)
RETURNS TABLE (
  booking_id uuid,
  booking_status public.booking_status,
  total_amount numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_customer_user_id uuid;
  v_request_hash text;
  v_existing_request public.customer_booking_requests%ROWTYPE;
  v_customer_id uuid;
  v_elder_profile_id uuid;
  v_elder_address_id uuid;
  v_booking_id uuid;
  v_booking_status public.booking_status;
  v_address_snapshot jsonb;
  v_caregiver_price numeric;
  v_total_amount numeric;
  v_canonical_payload jsonb;
  v_start_local timestamp without time zone;
  v_end_local timestamp without time zone;
  v_shift_count integer;
  v_shift_extra numeric := 0;
  v_subtotal numeric;
  v_discount_rate numeric := 0;
  v_discount_amount numeric;
  v_payment_method public.payment_method;
BEGIN
  CASE lower(btrim(COALESCE(p_payment_method, '')))
    WHEN 'qris' THEN v_payment_method := 'qris_demo'::public.payment_method;
    WHEN 'virtual_account' THEN v_payment_method := 'transfer_demo'::public.payment_method;
    WHEN 'cash' THEN v_payment_method := 'cash_demo'::public.payment_method;
    ELSE RAISE EXCEPTION 'Invalid payment method';
  END CASE;

  v_customer_user_id := auth.uid();

  IF v_customer_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Ensure user is authenticated and NOT anonymous
  IF COALESCE((auth.jwt() ->> 'is_anonymous')::boolean, false) IS TRUE THEN
    RAISE EXCEPTION 'Customer authenticated account required';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required';
  END IF;

  IF p_caregiver_id IS NULL THEN
    RAISE EXCEPTION 'Caregiver is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_customer_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Customer name is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_emergency_contact_name, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_emergency_contact_phone, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Emergency contact is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder name is required';
  END IF;

  IF p_elder_age IS NULL OR p_elder_age NOT BETWEEN 1 AND 150 THEN
    RAISE EXCEPTION 'Elder age must be an integer between 1 and 150';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_gender, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder gender is required';
  END IF;

  IF p_elder_conditions IS NULL
     OR jsonb_typeof(p_elder_conditions) <> 'array' THEN
    RAISE EXCEPTION 'Elder conditions must be a JSON array';
  END IF;

  IF jsonb_array_length(p_elder_conditions) = 0 THEN
    RAISE EXCEPTION 'Elder conditions must be a non-empty array';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_mobility, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder mobility is required';
  END IF;

  IF p_elder_mobility NOT IN ('mandiri', 'butuh_bantuan', 'tirah_baring') THEN
    RAISE EXCEPTION 'Invalid elder mobility';
  END IF;

  IF NULLIF(btrim(COALESCE(p_address_line, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_city, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_province, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Address is required';
  END IF;

  IF p_latitude IS NULL OR p_latitude < -90 OR p_latitude > 90
     OR p_longitude IS NULL OR p_longitude < -180 OR p_longitude > 180 THEN
    RAISE EXCEPTION 'Invalid coordinates';
  END IF;

  IF p_start_at IS NULL OR p_end_at IS NULL OR p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'Invalid booking time range';
  END IF;

  -- Derive shift schedule and rate rules (Asia/Jakarta timezone)
  -- Pagi: 08:00 - 16:00 (base rate)
  -- Malam: 20:00 - 08:00 (+30,000/shift)
  -- 24 Jam: 00:00 - 00:00 (+90,000/shift)
  v_start_local := p_start_at AT TIME ZONE 'Asia/Jakarta';
  v_end_local := p_end_at AT TIME ZONE 'Asia/Jakarta';

  IF v_start_local::time = time '08:00:00'
     AND v_end_local::time = time '16:00:00' THEN
    v_shift_count := (v_end_local::date - v_start_local::date) + 1;
    v_shift_extra := 0;
  ELSIF v_start_local::time = time '20:00:00'
        AND v_end_local::time = time '08:00:00' THEN
    v_shift_count := v_end_local::date - v_start_local::date;
    v_shift_extra := 30000;
  ELSIF v_start_local::time = time '00:00:00'
        AND v_end_local::time = time '00:00:00' THEN
    v_shift_count := v_end_local::date - v_start_local::date;
    v_shift_extra := 90000;
  ELSE
    RAISE EXCEPTION 'Booking time must match Pagi, Malam, or 24 Jam shift';
  END IF;

  IF v_shift_count IS NULL OR v_shift_count < 1 THEN
    RAISE EXCEPTION 'Booking duration must be at least one shift';
  END IF;

  IF v_shift_count = 30 THEN
    v_discount_rate := 0.12;
  ELSIF v_shift_count = 14 THEN
    v_discount_rate := 0.08;
  ELSIF v_shift_count = 7 THEN
    v_discount_rate := 0.05;
  ELSE
    v_discount_rate := 0;
  END IF;

  v_canonical_payload := jsonb_build_object(
    'caregiver_id', p_caregiver_id,
    'customer_name', NULLIF(btrim(p_customer_name), ''),
    'emergency_contact_name', NULLIF(btrim(COALESCE(p_emergency_contact_name, '')), ''),
    'emergency_contact_phone', NULLIF(btrim(COALESCE(p_emergency_contact_phone, '')), ''),
    'elder_name', NULLIF(btrim(COALESCE(p_elder_name, '')), ''),
    'elder_age', p_elder_age,
    'elder_gender', p_elder_gender,
    'elder_conditions', p_elder_conditions,
    'elder_allergies', p_elder_allergies,
    'elder_mobility', p_elder_mobility,
    'elder_medical_notes', p_elder_medical_notes,
    'address_line', NULLIF(btrim(COALESCE(p_address_line, '')), ''),
    'city', NULLIF(btrim(COALESCE(p_city, '')), ''),
    'province', NULLIF(btrim(COALESCE(p_province, '')), ''),
    'postal_code', NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    'latitude', p_latitude,
    'longitude', p_longitude,
    'access_notes', NULLIF(btrim(COALESCE(p_access_notes, '')), ''),
    'start_at', p_start_at,
    'end_at', p_end_at,
    'payment_method', v_payment_method
  );

  v_request_hash := encode(
    extensions.digest(convert_to(v_canonical_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  -- Serialize same customer/key retries before SELECT/INSERT
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      v_customer_user_id::text || ':' || p_idempotency_key::text,
      0
    )
  );

  -- Explicit role validation: require existing customer role, never self-provision
  IF NOT EXISTS (
    SELECT 1
    FROM public.user_roles ur
    WHERE ur.user_id = v_customer_user_id
      AND ur.role = 'customer'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Customer role is not provisioned';
  END IF;

  -- Verify profile exists and is linked
  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = v_customer_user_id
  ) THEN
    RAISE EXCEPTION 'Customer profile is not provisioned';
  END IF;

  SELECT *
    INTO v_existing_request
  FROM public.customer_booking_requests AS r
  WHERE r.customer_user_id = v_customer_user_id
    AND r.idempotency_key = p_idempotency_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_request.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'Idempotency key payload conflict';
    END IF;

    IF v_existing_request.completed_at IS NOT NULL
       AND v_existing_request.booking_id IS NULL THEN
      RAISE EXCEPTION 'Idempotency booking missing';
    END IF;

    IF v_existing_request.booking_id IS NOT NULL THEN
      SELECT b.id, b.status, b.total_amount
        INTO v_booking_id, v_booking_status, v_total_amount
      FROM public.bookings AS b
      WHERE b.id = v_existing_request.booking_id
        AND b.customer_id = v_customer_user_id;

      IF FOUND THEN
        RETURN QUERY SELECT v_booking_id, v_booking_status, v_total_amount;
        RETURN;
      END IF;

      RAISE EXCEPTION 'Idempotency booking missing';
    END IF;
  ELSE
    INSERT INTO public.customer_booking_requests (
      customer_user_id, idempotency_key, request_hash
    )
    VALUES (
      v_customer_user_id, p_idempotency_key, v_request_hash
    )
    RETURNING * INTO v_existing_request;
  END IF;

  -- Validate caregiver and snapshot server price
  SELECT c.price_per_shift
    INTO v_caregiver_price
  FROM public.caregivers AS c
  WHERE c.id = p_caregiver_id
    AND c.is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caregiver is not active';
  END IF;

  IF v_caregiver_price IS NULL OR v_caregiver_price < 0 THEN
    RAISE EXCEPTION 'Invalid caregiver price';
  END IF;

  v_subtotal := (v_caregiver_price + v_shift_extra) * v_shift_count;
  v_discount_amount := round(v_subtotal * v_discount_rate);
  v_total_amount := v_subtotal - v_discount_amount + 15000;

  IF v_total_amount IS NULL OR v_total_amount < 0 THEN
    RAISE EXCEPTION 'Invalid calculated booking total';
  END IF;

  v_customer_id := v_customer_user_id;

  INSERT INTO public.customers (
    id, emergency_contact_name, emergency_contact_phone
  )
  VALUES (
    v_customer_id,
    btrim(p_emergency_contact_name),
    btrim(p_emergency_contact_phone)
  )
  ON CONFLICT (id) DO UPDATE SET
    emergency_contact_name = EXCLUDED.emergency_contact_name,
    emergency_contact_phone = EXCLUDED.emergency_contact_phone,
    updated_at = now();

  INSERT INTO public.elder_profiles (
    customer_id, name, elder_age, gender, conditions,
    allergies, mobility, medical_notes
  )
  VALUES (
    v_customer_id,
    btrim(p_elder_name),
    p_elder_age,
    p_elder_gender,
    p_elder_conditions,
    p_elder_allergies,
    p_elder_mobility,
    p_elder_medical_notes
  )
  RETURNING id INTO v_elder_profile_id;

  INSERT INTO public.elder_addresses (
    elder_profile_id, address_line, city, province, postal_code,
    latitude, longitude, access_notes, is_default
  )
  VALUES (
    v_elder_profile_id,
    btrim(p_address_line),
    btrim(p_city),
    btrim(p_province),
    NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    p_latitude,
    p_longitude,
    NULLIF(btrim(COALESCE(p_access_notes, '')), ''),
    true
  )
  RETURNING id INTO v_elder_address_id;

  v_address_snapshot := jsonb_build_object(
    'address_line', btrim(p_address_line),
    'city', btrim(p_city),
    'province', btrim(p_province),
    'postal_code', NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    'latitude', p_latitude,
    'longitude', p_longitude,
    'access_notes', NULLIF(btrim(COALESCE(p_access_notes, '')), '')
  );

  INSERT INTO public.bookings (
    customer_id, caregiver_id, elder_profile_id, elder_address_id,
    start_at, end_at, status, total_amount, address_snapshot, payment_method
  )
  VALUES (
    v_customer_id,
    p_caregiver_id,
    v_elder_profile_id,
    v_elder_address_id,
    p_start_at,
    p_end_at,
    'pending'::public.booking_status,
    v_total_amount,
    v_address_snapshot,
    v_payment_method
  )
  RETURNING id, status INTO v_booking_id, v_booking_status;

  UPDATE public.customer_booking_requests
  SET booking_id = v_booking_id, completed_at = now()
  WHERE id = v_existing_request.id;

  RETURN QUERY SELECT v_booking_id, v_booking_status, v_total_amount;
END;
$function$;


CREATE OR REPLACE FUNCTION public.create_anonymous_booking(
  p_idempotency_key uuid,
  p_caregiver_id uuid,
  p_customer_name text,
  p_emergency_contact_name text,
  p_emergency_contact_phone text,
  p_elder_name text,
  p_elder_age integer,
  p_elder_gender text,
  p_elder_conditions jsonb,
  p_elder_allergies text,
  p_elder_mobility text,
  p_elder_medical_notes text,
  p_address_line text,
  p_city text,
  p_province text,
  p_postal_code text,
  p_latitude numeric,
  p_longitude numeric,
  p_access_notes text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_payment_method text
)
RETURNS TABLE (
  booking_id uuid,
  booking_status public.booking_status
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_guest_user_id uuid;
  v_request_hash text;
  v_existing_request public.guest_booking_requests%ROWTYPE;
  v_customer_id uuid;
  v_elder_profile_id uuid;
  v_elder_address_id uuid;
  v_booking_id uuid;
  v_booking_status public.booking_status;
  v_address_snapshot jsonb;
  v_caregiver_price numeric;
  v_total_amount numeric;
  v_canonical_payload jsonb;
  v_start_local timestamp without time zone;
  v_end_local timestamp without time zone;
  v_shift_count integer;
  v_shift_extra numeric := 0;
  v_subtotal numeric;
  v_discount_rate numeric := 0;
  v_discount_amount numeric;
  v_payment_method public.payment_method;
BEGIN
  CASE lower(btrim(COALESCE(p_payment_method, '')))
    WHEN 'qris' THEN v_payment_method := 'qris_demo'::public.payment_method;
    WHEN 'virtual_account' THEN v_payment_method := 'transfer_demo'::public.payment_method;
    WHEN 'cash' THEN v_payment_method := 'cash_demo'::public.payment_method;
    ELSE RAISE EXCEPTION 'Invalid payment method';
  END CASE;

  v_guest_user_id := auth.uid();

  IF v_guest_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF COALESCE((auth.jwt() ->> 'is_anonymous')::boolean, false)
     IS NOT TRUE THEN
    RAISE EXCEPTION 'Anonymous authentication required';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'Idempotency key is required';
  END IF;

  IF p_caregiver_id IS NULL THEN
    RAISE EXCEPTION 'Caregiver is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_customer_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Customer name is required';
  END IF;

  v_canonical_payload := jsonb_build_object(
    'caregiver_id', p_caregiver_id,
    'customer_name', NULLIF(btrim(p_customer_name), ''),
    'emergency_contact_name', NULLIF(btrim(COALESCE(p_emergency_contact_name, '')), ''),
    'emergency_contact_phone', NULLIF(btrim(COALESCE(p_emergency_contact_phone, '')), ''),
    'elder_name', NULLIF(btrim(COALESCE(p_elder_name, '')), ''),
    'elder_age', p_elder_age,
    'elder_gender', p_elder_gender,
    'elder_conditions', p_elder_conditions,
    'elder_allergies', p_elder_allergies,
    'elder_mobility', p_elder_mobility,
    'elder_medical_notes', p_elder_medical_notes,
    'address_line', NULLIF(btrim(COALESCE(p_address_line, '')), ''),
    'city', NULLIF(btrim(COALESCE(p_city, '')), ''),
    'province', NULLIF(btrim(COALESCE(p_province, '')), ''),
    'postal_code', NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    'latitude', p_latitude,
    'longitude', p_longitude,
    'access_notes', NULLIF(btrim(COALESCE(p_access_notes, '')), ''),
    'start_at', p_start_at,
    'end_at', p_end_at,
    'payment_method', v_payment_method
  );

  v_request_hash := encode(
    extensions.digest(convert_to(v_canonical_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  /* Serialize same guest/key retries before SELECT/INSERT. */
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      v_guest_user_id::text || ':' || p_idempotency_key::text,
      0
    )
  );

  SELECT *
    INTO v_existing_request
  FROM public.guest_booking_requests AS r
  WHERE r.guest_user_id = v_guest_user_id
    AND r.idempotency_key = p_idempotency_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_request.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'Idempotency key payload conflict';
    END IF;

    IF v_existing_request.completed_at IS NOT NULL
       AND v_existing_request.booking_id IS NULL THEN
      RAISE EXCEPTION 'Idempotency booking missing';
    END IF;

    IF v_existing_request.booking_id IS NOT NULL THEN
      SELECT b.id, b.status
        INTO v_booking_id, v_booking_status
      FROM public.bookings AS b
      WHERE b.id = v_existing_request.booking_id;

      IF FOUND THEN
        RETURN QUERY SELECT v_booking_id, v_booking_status;
        RETURN;
      END IF;

      RAISE EXCEPTION 'Idempotency booking missing';
    END IF;
  ELSE
    INSERT INTO public.guest_booking_requests (
      guest_user_id, idempotency_key, request_hash
    )
    VALUES (
      v_guest_user_id, p_idempotency_key, v_request_hash
    )
    RETURNING * INTO v_existing_request;
  END IF;

  /* New request only: validate caregiver and snapshot server price. */
  SELECT c.price_per_shift
    INTO v_caregiver_price
  FROM public.caregivers AS c
  WHERE c.id = p_caregiver_id
    AND c.is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caregiver is not active';
  END IF;

  IF v_caregiver_price IS NULL OR v_caregiver_price < 0 THEN
    RAISE EXCEPTION 'Invalid caregiver price';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles AS p
    WHERE p.id = v_guest_user_id
  ) THEN
    RAISE EXCEPTION 'Guest profile is not provisioned';
  END IF;

  -- Persist only the current Auth user's submitted name.
  UPDATE public.profiles
  SET full_name = btrim(p_customer_name),
      updated_at = now()
  WHERE id = v_guest_user_id;

  IF NULLIF(btrim(COALESCE(p_emergency_contact_name, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_emergency_contact_phone, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Emergency contact is required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder name is required';
  END IF;

  IF p_elder_age IS NULL OR p_elder_age NOT BETWEEN 1 AND 150 THEN
    RAISE EXCEPTION 'Elder age must be an integer between 1 and 150';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_gender, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder gender is required';
  END IF;

  IF p_elder_conditions IS NULL
     OR jsonb_typeof(p_elder_conditions) <> 'array' THEN
    RAISE EXCEPTION 'Elder conditions must be a JSON array';
  END IF;

  IF jsonb_array_length(p_elder_conditions) = 0 THEN
    RAISE EXCEPTION 'Elder conditions must be a non-empty array';
  END IF;

  IF NULLIF(btrim(COALESCE(p_elder_mobility, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Elder mobility is required';
  END IF;

  IF p_elder_mobility NOT IN ('mandiri', 'butuh_bantuan', 'tirah_baring') THEN
    RAISE EXCEPTION 'Invalid elder mobility';
  END IF;

  IF NULLIF(btrim(COALESCE(p_address_line, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_city, '')), '') IS NULL
     OR NULLIF(btrim(COALESCE(p_province, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Address is required';
  END IF;

  IF p_latitude IS NULL OR p_latitude < -90 OR p_latitude > 90
     OR p_longitude IS NULL OR p_longitude < -180 OR p_longitude > 180 THEN
    RAISE EXCEPTION 'Invalid coordinates';
  END IF;

  IF p_start_at IS NULL OR p_end_at IS NULL OR p_end_at <= p_start_at THEN
    RAISE EXCEPTION 'Invalid booking time range';
  END IF;

  -- Canonical server pricing: identical to create_customer_booking.
  v_start_local := p_start_at AT TIME ZONE 'Asia/Jakarta';
  v_end_local := p_end_at AT TIME ZONE 'Asia/Jakarta';

  IF v_start_local::time = time '08:00:00'
     AND v_end_local::time = time '16:00:00' THEN
    v_shift_count := (v_end_local::date - v_start_local::date) + 1;
    v_shift_extra := 0;
  ELSIF v_start_local::time = time '20:00:00'
        AND v_end_local::time = time '08:00:00' THEN
    v_shift_count := v_end_local::date - v_start_local::date;
    v_shift_extra := 30000;
  ELSIF v_start_local::time = time '00:00:00'
        AND v_end_local::time = time '00:00:00' THEN
    v_shift_count := v_end_local::date - v_start_local::date;
    v_shift_extra := 90000;
  ELSE
    RAISE EXCEPTION 'Booking time must match Pagi, Malam, or 24 Jam shift';
  END IF;

  IF v_shift_count IS NULL OR v_shift_count < 1 THEN
    RAISE EXCEPTION 'Booking duration must be at least one shift';
  END IF;

  IF v_shift_count = 30 THEN
    v_discount_rate := 0.12;
  ELSIF v_shift_count = 14 THEN
    v_discount_rate := 0.08;
  ELSIF v_shift_count = 7 THEN
    v_discount_rate := 0.05;
  ELSE
    v_discount_rate := 0;
  END IF;

  v_subtotal := (v_caregiver_price + v_shift_extra) * v_shift_count;
  v_discount_amount := round(v_subtotal * v_discount_rate);
  v_total_amount := v_subtotal - v_discount_amount + 15000;

  IF v_total_amount IS NULL OR v_total_amount < 0 THEN
    RAISE EXCEPTION 'Invalid calculated booking total';
  END IF;

  v_customer_id := v_guest_user_id;

  INSERT INTO public.customers (
    id, customer_name, emergency_contact_name, emergency_contact_phone
  )
  VALUES (
    v_customer_id,
    btrim(p_customer_name),
    btrim(p_emergency_contact_name),
    btrim(p_emergency_contact_phone)
  )
  ON CONFLICT (id) DO UPDATE SET
    customer_name = EXCLUDED.customer_name,
    emergency_contact_name = EXCLUDED.emergency_contact_name,
    emergency_contact_phone = EXCLUDED.emergency_contact_phone,
    updated_at = now();

  INSERT INTO public.elder_profiles (
    customer_id, name, elder_age, gender, conditions,
    allergies, mobility, medical_notes
  )
  VALUES (
    v_customer_id,
    btrim(p_elder_name),
    p_elder_age,
    p_elder_gender,
    p_elder_conditions,
    p_elder_allergies,
    p_elder_mobility,
    p_elder_medical_notes
  )
  RETURNING id INTO v_elder_profile_id;

  INSERT INTO public.elder_addresses (
    elder_profile_id, address_line, city, province, postal_code,
    latitude, longitude, access_notes, is_default
  )
  VALUES (
    v_elder_profile_id,
    btrim(p_address_line),
    btrim(p_city),
    btrim(p_province),
    NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    p_latitude,
    p_longitude,
    NULLIF(btrim(COALESCE(p_access_notes, '')), ''),
    true
  )
  RETURNING id INTO v_elder_address_id;

  v_address_snapshot := jsonb_build_object(
    'address_line', btrim(p_address_line),
    'city', btrim(p_city),
    'province', btrim(p_province),
    'postal_code', NULLIF(btrim(COALESCE(p_postal_code, '')), ''),
    'latitude', p_latitude,
    'longitude', p_longitude,
    'access_notes', NULLIF(btrim(COALESCE(p_access_notes, '')), '')
  );

  INSERT INTO public.bookings (
    customer_id, caregiver_id, elder_profile_id, elder_address_id,
    start_at, end_at, status, total_amount, address_snapshot, payment_method
  )
  VALUES (
    v_customer_id,
    p_caregiver_id,
    v_elder_profile_id,
    v_elder_address_id,
    p_start_at,
    p_end_at,
    'pending'::public.booking_status,
    v_total_amount,
    v_address_snapshot,
    v_payment_method
  )
  RETURNING id, status INTO v_booking_id, v_booking_status;

  UPDATE public.guest_booking_requests
  SET booking_id = v_booking_id, completed_at = now()
  WHERE id = v_existing_request.id;

  RETURN QUERY SELECT v_booking_id, v_booking_status;
END;
$function$;


CREATE OR REPLACE FUNCTION public.create_customer_booking(
  p_idempotency_key uuid, p_caregiver_id uuid, p_customer_name text,
  p_emergency_contact_name text, p_emergency_contact_phone text,
  p_elder_name text, p_elder_age integer, p_elder_gender text,
  p_elder_conditions jsonb, p_elder_allergies text, p_elder_mobility text,
  p_elder_medical_notes text, p_address_line text, p_city text,
  p_province text, p_postal_code text, p_latitude numeric, p_longitude numeric,
  p_access_notes text, p_start_at timestamptz, p_end_at timestamptz
)
RETURNS TABLE (booking_id uuid, booking_status public.booking_status, total_amount numeric)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $$
  SELECT * FROM public.create_customer_booking(
    p_idempotency_key, p_caregiver_id, p_customer_name, p_emergency_contact_name, p_emergency_contact_phone, p_elder_name, p_elder_age, p_elder_gender, p_elder_conditions, p_elder_allergies, p_elder_mobility, p_elder_medical_notes, p_address_line, p_city, p_province, p_postal_code, p_latitude, p_longitude, p_access_notes, p_start_at, p_end_at, 'qris'
  );
$$;


CREATE OR REPLACE FUNCTION public.create_anonymous_booking(
  p_idempotency_key uuid, p_caregiver_id uuid, p_customer_name text,
  p_emergency_contact_name text, p_emergency_contact_phone text,
  p_elder_name text, p_elder_age integer, p_elder_gender text,
  p_elder_conditions jsonb, p_elder_allergies text, p_elder_mobility text,
  p_elder_medical_notes text, p_address_line text, p_city text,
  p_province text, p_postal_code text, p_latitude numeric, p_longitude numeric,
  p_access_notes text, p_start_at timestamptz, p_end_at timestamptz
)
RETURNS TABLE (booking_id uuid, booking_status public.booking_status)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $$
  SELECT booking_id, booking_status FROM public.create_anonymous_booking(
    p_idempotency_key, p_caregiver_id, p_customer_name, p_emergency_contact_name, p_emergency_contact_phone, p_elder_name, p_elder_age, p_elder_gender, p_elder_conditions, p_elder_allergies, p_elder_mobility, p_elder_medical_notes, p_address_line, p_city, p_province, p_postal_code, p_latitude, p_longitude, p_access_notes, p_start_at, p_end_at, 'qris'
  );
$$;


-- Minimum grants. Existing ACLs must be reviewed against staging before execution.
REVOKE ALL ON FUNCTION public.create_customer_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_customer_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text) TO authenticated;
REVOKE ALL ON FUNCTION public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text) TO anon;

-- Static postflight. Any failure rolls back all changes.
DO $$
BEGIN
  IF to_regprocedure('public.create_customer_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text)') IS NULL THEN RAISE EXCEPTION 'postflight: new customer signature missing'; END IF;
  IF to_regprocedure('public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamptz,timestamptz,text)') IS NULL THEN RAISE EXCEPTION 'postflight: new anonymous signature missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid='public.bookings'::regclass AND attname='payment_method') THEN RAISE EXCEPTION 'postflight: payment_method missing'; END IF;
END $$;

-- Review rollback only; do not execute automatically. To rollback safely after staging:
-- DROP new overloads; restore original trigger/function from approved migration; DROP COLUMN only if no dependent data/objects.
COMMIT;
