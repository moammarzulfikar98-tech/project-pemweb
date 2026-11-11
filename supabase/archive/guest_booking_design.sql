-- DESIGN ONLY: Guest Booking migration and RPC.
-- NOT EXECUTED. Review against live metadata before approval.
-- Scope: guest_booking_requests, customer_name compatibility column,
-- caregiver-owned booking SELECT policy, create_anonymous_booking RPC.
-- No backfill, payment, frontend, or caregiver data.
-- Pricing contract in this design: server derives the same shift surcharge,
-- exact-duration discount, and fixed fee as the numbered booking migrations.
-- Client price input is never accepted.
-- SHA-256 uses extensions.digest(bytea, text) supplied by pgcrypto.
-- Target metadata confirms pgcrypto and extensions.digest owner postgres.
-- Target privilege CSV confirms postgres can access existing source tables;
-- guest_booking_requests privileges are created by this migration, then used by its definer function.
-- Existing metadata confirms bookings_no_overlap and no existing bookings SELECT policy.
-- Source-table privileges for migration executor postgres are confirmed; new-table
-- privilege and effective post-create function owner remain runtime checks.

BEGIN;

-- Tahap A already verified:
-- public.customers.customer_name text exists and is nullable.
-- Tahap B does not alter public.customers.

CREATE TABLE public.guest_booking_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  guest_user_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  idempotency_key uuid NOT NULL,
  request_hash text NOT NULL,
  booking_id uuid NULL
    REFERENCES public.bookings(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz NULL,
  CONSTRAINT guest_booking_requests_guest_key_unique
    UNIQUE (guest_user_id, idempotency_key),
  CONSTRAINT guest_booking_requests_hash_not_blank
    CHECK (btrim(request_hash) <> '')
);

CREATE INDEX guest_booking_requests_booking_id_idx
  ON public.guest_booking_requests (booking_id);

ALTER TABLE public.guest_booking_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.guest_booking_requests FROM PUBLIC, anon, authenticated;

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

-- Do not drop existing policies. CREATE fails closed if migration name already exists.
CREATE POLICY caregiver_read_own_bookings
  ON public.bookings
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.caregivers AS c
      WHERE c.id = bookings.caregiver_id
        AND c.user_id = auth.uid()
        AND c.is_active = true
    )
  );

GRANT SELECT ON TABLE public.bookings TO authenticated;

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

  -- Canonical server pricing: same rules as authenticated booking.
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

-- ROLLBACK DESIGN: execute only after separate approval.
-- DROP FUNCTION public.create_anonymous_booking(
--   uuid, uuid, text, text, text, text, integer, text, jsonb, text,
--   text, text, text, text, text, text, numeric, numeric, text,
--   timestamptz, timestamptz
-- );
-- DROP POLICY caregiver_read_own_bookings ON public.bookings;
-- Fail-closed table rollback; never delete production rows.
-- DO $$
-- BEGIN
--   IF EXISTS (SELECT 1 FROM public.guest_booking_requests) THEN
--     RAISE EXCEPTION 'Rollback blocked: guest_booking_requests is not empty';
--   END IF;
-- END
-- $$;
-- DROP TABLE public.guest_booking_requests;
