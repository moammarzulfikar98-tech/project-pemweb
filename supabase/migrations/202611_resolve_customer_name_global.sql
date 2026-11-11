-- =============================================================================
-- MIGRATION: 202611_resolve_customer_name_global.sql
-- PURPOSE  : Memperbaiki resolusi nama customer secara global pada RPC
--            public.get_assigned_customer_details(p_booking_id uuid)
--            agar mengambil profiles.full_name dengan fallback customers.customer_name.
--            TIDAK DIJALANKAN OTOMATIS (Menunggu persetujuan user).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_assigned_customer_details(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_caregiver public.caregivers;
  v_caregiver_count integer;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'caregiver authentication required';
  END IF;

  SELECT count(*)::integer
    INTO v_caregiver_count
  FROM public.caregivers AS c
  WHERE c.user_id = v_uid
    AND c.is_active = true;

  IF v_caregiver_count = 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'booking not found';
  ELSIF v_caregiver_count > 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'caregiver ownership is not unique';
  END IF;

  SELECT c.*
    INTO v_caregiver
  FROM public.caregivers AS c
  WHERE c.user_id = v_uid
    AND c.is_active = true;

  SELECT jsonb_build_object(
    'booking_id', b.id,
    'assigned_caregiver_id', c.id,
    'assigned_caregiver_name', c.name,
    'customer_id', b.customer_id,
    'customer_name', COALESCE(
      NULLIF(TRIM(p.full_name), ''),
      NULLIF(TRIM(cu.customer_name), '')
    ),
    'customer_contact_name', cu.emergency_contact_name,
    'customer_contact_phone', cu.emergency_contact_phone,
    'elder_profile_id', e.id,
    'elder_name', e.name,
    'elder_age', e.elder_age,
    'elder_gender', e.gender,
    'health_conditions', e.conditions,
    'allergies', e.allergies,
    'mobility', e.mobility,
    'medical_notes', e.medical_notes,
    'address_id', ea.id,
    'address_line', ea.address_line,
    'city', ea.city,
    'province', ea.province,
    'postal_code', ea.postal_code,
    'access_notes', ea.access_notes,
    'address_snapshot', b.address_snapshot,
    'start_at', b.start_at,
    'end_at', b.end_at,
    'shift_type', CASE
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '08:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '16:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date >= (b.start_at AT TIME ZONE 'Asia/Jakarta')::date THEN 'Pagi'
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '20:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '08:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date > (b.start_at AT TIME ZONE 'Asia/Jakarta')::date THEN 'Malam'
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '00:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '00:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date > (b.start_at AT TIME ZONE 'Asia/Jakarta')::date THEN '24 Jam'
      ELSE NULL
    END,
    'duration_hours', CASE
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '08:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '16:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date >= (b.start_at AT TIME ZONE 'Asia/Jakarta')::date
        THEN 8 * ((b.end_at AT TIME ZONE 'Asia/Jakarta')::date - (b.start_at AT TIME ZONE 'Asia/Jakarta')::date + 1)
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '20:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '08:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date > (b.start_at AT TIME ZONE 'Asia/Jakarta')::date THEN 12
      WHEN (b.start_at AT TIME ZONE 'Asia/Jakarta')::time = time '00:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::time = time '00:00'
       AND (b.end_at AT TIME ZONE 'Asia/Jakarta')::date > (b.start_at AT TIME ZONE 'Asia/Jakarta')::date THEN 24
      ELSE NULL
    END,
    'booking_status', b.status,
    'total_amount', b.total_amount
  )
  INTO v_result
  FROM public.bookings AS b
  JOIN public.caregivers AS c ON c.id = b.caregiver_id
  LEFT JOIN public.profiles AS p ON p.id = b.customer_id
  LEFT JOIN public.customers AS cu ON cu.id = b.customer_id
  LEFT JOIN public.elder_profiles AS e ON e.id = b.elder_profile_id
  LEFT JOIN public.elder_addresses AS ea
    ON ea.id = b.elder_address_id
   AND ea.elder_profile_id = b.elder_profile_id
  WHERE b.id = p_booking_id
    AND b.caregiver_id = v_caregiver.id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'booking not found';
  END IF;

  RETURN v_result;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'booking not found';
END
$function$;

REVOKE ALL ON FUNCTION public.get_assigned_customer_details(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_assigned_customer_details(uuid) TO authenticated;
