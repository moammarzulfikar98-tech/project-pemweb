-- REVIEW ONLY. Do not execute without explicit approval.
-- Adds nullable elder_age; preserves date_of_birth and all existing rows.
-- Switches create_anonymous_booking from DATE to INTEGER.
-- Dependencies: guest_booking_design.sql and stepA_customer_name.sql.
BEGIN;

DO $$
DECLARE
  missing text;
  mismatch text;
BEGIN
  SELECT string_agg(x, ', ') INTO missing
  FROM (VALUES
    ('public.elder_profiles'), ('public.bookings'),
    ('public.customers'), ('public.caregivers'), ('public.profiles'),
    ('public.guest_booking_requests')
  ) AS required(x)
  WHERE to_regclass(x) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'Preflight missing relation(s): %', missing;
  END IF;

  WITH expected(table_name, column_name, expected_type, expected_not_null) AS (
    VALUES
      ('guest_booking_requests', 'id', 'uuid', true),
      ('guest_booking_requests', 'guest_user_id', 'uuid', true),
      ('guest_booking_requests', 'idempotency_key', 'uuid', true),
      ('guest_booking_requests', 'request_hash', 'text', true),
      ('guest_booking_requests', 'booking_id', 'uuid', false),
      ('guest_booking_requests', 'created_at', 'timestamp with time zone', true),
      ('guest_booking_requests', 'completed_at', 'timestamp with time zone', false)
  )
  SELECT string_agg(
           format('%s.%s expected %s%s', x.table_name, x.column_name,
             x.expected_type,
             CASE WHEN x.expected_not_null THEN ' NOT NULL' ELSE ' NULLABLE' END),
           ', ' ORDER BY x.column_name
         )
    INTO mismatch
  FROM expected x
  LEFT JOIN pg_attribute a
    ON a.attrelid = 'public.guest_booking_requests'::regclass
   AND a.attname = x.column_name
   AND a.attnum > 0
   AND NOT a.attisdropped
  WHERE a.attnum IS NULL
     OR a.atttypid IS DISTINCT FROM pg_catalog.to_regtype(x.expected_type)::oid
     OR a.attnotnull IS DISTINCT FROM x.expected_not_null;

  IF mismatch IS NOT NULL THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests schema mismatch: %', mismatch;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.guest_booking_requests'::regclass
      AND c.contype = 'p'
      AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
        WHERE attrelid = c.conrelid AND attname = 'id')]::smallint[]
  ) THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests primary key missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.guest_booking_requests'::regclass
      AND c.contype IN ('u', 'p')
      AND c.conkey = ARRAY[
        (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'guest_user_id'),
        (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'idempotency_key')
      ]::smallint[]
  ) THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests user/idempotency uniqueness missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.guest_booking_requests'::regclass
      AND c.contype = 'f'
      AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
        WHERE attrelid = c.conrelid AND attname = 'guest_user_id')]::smallint[]
      AND c.confrelid = 'auth.users'::regclass
      AND c.confdeltype = 'c'
  ) THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests guest_user_id FK missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.guest_booking_requests'::regclass
      AND c.contype = 'f'
      AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
        WHERE attrelid = c.conrelid AND attname = 'booking_id')]::smallint[]
      AND c.confrelid = 'public.bookings'::regclass
      AND c.confdeltype = 'n'
  ) THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests booking_id FK missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = 'public.guest_booking_requests'::regclass
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%request_hash%'
  ) THEN
    RAISE EXCEPTION 'Preflight guest_booking_requests request_hash check missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = 'public.customers'::regclass
      AND attname = 'customer_name'
      AND atttypid = pg_catalog.to_regtype('text')::oid
      AND attnotnull = false
      AND attnum > 0
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Preflight failed; public.customers.customer_name must be nullable text';
  END IF;

  -- Accept either the legacy DATE contract or the already-prepared INTEGER
  -- contract from guest_booking_design.sql. The latter is normalized below;
  -- rejecting it here made the numbered dependency chain self-contradictory.
  IF pg_catalog.to_regprocedure(
       'public.create_anonymous_booking(uuid,uuid,text,text,text,text,date,text,jsonb,text,text,text,text,text,text,numeric,numeric,text,timestamp with time zone,timestamp with time zone)'
     ) IS NULL
     AND pg_catalog.to_regprocedure(
       'public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,numeric,numeric,text,timestamp with time zone,timestamp with time zone)'
     ) IS NULL THEN
    RAISE EXCEPTION 'Preflight failed; DATE or INTEGER create_anonymous_booking signature is missing';
  END IF;
END $$;

ALTER TABLE public.elder_profiles
  ADD COLUMN IF NOT EXISTS elder_age integer;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.elder_profiles'::regclass
      AND conname = 'elder_profiles_elder_age_range'
  ) THEN
    ALTER TABLE public.elder_profiles
      ADD CONSTRAINT elder_profiles_elder_age_range
      CHECK (elder_age IS NULL OR elder_age BETWEEN 1 AND 150) NOT VALID;
  END IF;
END $$;

ALTER TABLE public.elder_profiles
  VALIDATE CONSTRAINT elder_profiles_elder_age_range;

-- Old signature must be removed before new integer signature is created.
DROP FUNCTION IF EXISTS public.create_anonymous_booking(
  uuid, uuid, text, text, text, text, date, text, jsonb, text,
  text, text, text, text, text, text, text, numeric, numeric, text,
  timestamptz, timestamptz
);

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
  p_end_at timestamptz
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
BEGIN
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
    'end_at', p_end_at
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
    start_at, end_at, status, total_amount, address_snapshot
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
    v_address_snapshot
  )
  RETURNING id, status INTO v_booking_id, v_booking_status;

  UPDATE public.guest_booking_requests
  SET booking_id = v_booking_id, completed_at = now()
  WHERE id = v_existing_request.id;

  RETURN QUERY SELECT v_booking_id, v_booking_status;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_anonymous_booking(
  uuid, uuid, text, text, text, text, integer, text, jsonb, text,
  text, text, text, text, text, text, numeric, numeric, text,
  timestamptz, timestamptz
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_anonymous_booking(
  uuid, uuid, text, text, text, text, integer, text, jsonb, text,
  text, text, text, text, text, text, numeric, numeric, text,
  timestamptz, timestamptz
) TO authenticated;


COMMIT;

-- ROLLBACK REVIEW ONLY. Do not run while age-based rows or new RPC calls exist.
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.create_anonymous_booking(
--   uuid, uuid, text, text, text, text, integer, text, jsonb, text,
--   text, text, text, text, text, text, text, numeric, numeric, text,
--   timestamptz, timestamptz
-- );
-- ALTER TABLE public.elder_profiles
--   DROP CONSTRAINT IF EXISTS elder_profiles_elder_age_range;
-- ALTER TABLE public.elder_profiles DROP COLUMN IF EXISTS elder_age;
-- Restore old DATE RPC from version-controlled pre-migration SQL.
-- COMMIT;
