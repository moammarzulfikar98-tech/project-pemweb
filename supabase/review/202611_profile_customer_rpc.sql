-- REVIEW DRAFT ONLY. Do not execute without separate approval.
-- Scope: caregiver self-profile RPC, assigned-customer detail RPC, caregiver
-- Storage ownership policies. No booking/auth migration changes.

BEGIN;

-- Fail closed if names are already occupied by an unreviewed routine.
DO $preflight_caregiver_review$
BEGIN
  IF to_regprocedure('public.update_my_caregiver_profile(jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'review RPC already exists: public.update_my_caregiver_profile(jsonb)';
  END IF;
  IF to_regprocedure('public.get_assigned_customer_details(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'review RPC already exists: public.get_assigned_customer_details(uuid)';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('caregivers', 'languages', 'jsonb'),
      ('caregivers', 'updated_at', 'timestamp with time zone'),
      ('elder_profiles', 'conditions', 'jsonb')
    ) AS x(table_name, column_name, expected_type)
    LEFT JOIN pg_attribute a
      ON a.attrelid = format('public.%s', x.table_name)::regclass
     AND a.attname = x.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    WHERE a.attnum IS NULL
       OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_type)::oid
  ) THEN
    RAISE EXCEPTION 'caregiver review preflight failed; required column type mismatch';
  END IF;

  -- Storage must already be provisioned privately. This draft never changes
  -- bucket visibility and fails closed when bucket state is unknown.
  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets b
    WHERE b.id = 'caregiver-media'
      AND b.public = false
  ) THEN
    RAISE EXCEPTION 'caregiver review preflight failed; caregiver-media bucket missing or public';
  END IF;

  -- Never silently collide with an existing policy owned by another change.
  IF EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'storage'
      AND p.tablename = 'objects'
      AND p.policyname = ANY (ARRAY[
        'caregiver_media_read_self',
        'caregiver_media_insert_self',
        'caregiver_media_update_self',
        'caregiver_media_delete_self'
      ])
  ) THEN
    RAISE EXCEPTION 'caregiver review preflight failed; target Storage policy already exists';
  END IF;

  -- Audit unknown permissive access per command. Read policies use qual;
  -- write policies use with_check; UPDATE requires both. A NULL relevant
  -- expression is broad access and fails closed. A policy whose relevant
  -- expression does not name caregiver-media is not accepted as scoped proof.
  IF EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'storage'
      AND p.tablename = 'objects'
      AND p.permissive = 'PERMISSIVE'
      AND p.policyname <> ALL (ARRAY[
        'caregiver_media_read_self',
        'caregiver_media_insert_self',
        'caregiver_media_update_self',
        'caregiver_media_delete_self'
      ])
      AND (
        (p.cmd IN ('SELECT', 'DELETE')
         AND (p.qual IS NULL OR p.qual NOT ILIKE '%caregiver-media%'))
        OR (p.cmd = 'INSERT'
         AND (p.with_check IS NULL OR p.with_check NOT ILIKE '%caregiver-media%'))
        OR (p.cmd = 'UPDATE'
         AND (p.qual IS NULL OR p.with_check IS NULL
              OR p.qual NOT ILIKE '%caregiver-media%'
              OR p.with_check NOT ILIKE '%caregiver-media%'))
        OR (p.cmd = 'ALL'
         AND (p.qual IS NULL OR p.with_check IS NULL
              OR p.qual NOT ILIKE '%caregiver-media%'
              OR p.with_check NOT ILIKE '%caregiver-media%'))
      )
  ) THEN
    RAISE EXCEPTION 'caregiver review preflight failed; unknown permissive Storage policy affects caregiver-media';
  END IF;
END
$preflight_caregiver_review$;

CREATE FUNCTION public.update_my_caregiver_profile(p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_caregiver public.caregivers;
  v_caregiver_count integer;
  v_unknown text;
  v_keys text[];
  v_photo_path text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'caregiver authentication required';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' OR p_patch = '{}'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'profile patch must be a non-empty object';
  END IF;

  SELECT array_agg(key ORDER BY key)
    INTO v_keys
  FROM jsonb_object_keys(p_patch) AS key;

  SELECT string_agg(key, ', ' ORDER BY key)
    INTO v_unknown
  FROM unnest(v_keys) AS key
  WHERE key NOT IN (
    'name', 'role', 'category', 'gender', 'age', 'city', 'area',
    'languages', 'description', 'photo_path'
  );

  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003',
      MESSAGE = format('unknown caregiver profile fields: %s', v_unknown);
  END IF;

  SELECT count(*)::integer
    INTO v_caregiver_count
  FROM public.caregivers AS c
  WHERE c.user_id = v_uid
    AND c.is_active = true;

  IF v_caregiver_count = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'caregiver ownership denied';
  ELSIF v_caregiver_count > 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'caregiver ownership is not unique';
  END IF;

  SELECT c.*
    INTO v_caregiver
  FROM public.caregivers AS c
  WHERE c.user_id = v_uid
    AND c.is_active = true;

  IF p_patch ? 'age'
     AND (p_patch->'age' IS NULL OR jsonb_typeof(p_patch->'age') <> 'number'
          OR (p_patch->>'age')::numeric <> trunc((p_patch->>'age')::numeric)
          OR (p_patch->>'age')::integer NOT BETWEEN 18 AND 100) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'age must be an integer from 18 to 100';
  END IF;

  IF p_patch ? 'languages'
     AND (p_patch->'languages' IS NULL OR jsonb_typeof(p_patch->'languages') <> 'array'
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_patch->'languages') AS item
            WHERE jsonb_typeof(item) <> 'string' OR btrim(item #>> '{}') = ''
          )) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'languages must be an array of non-empty strings';
  END IF;

  IF p_patch ? 'photo_path' THEN
    v_photo_path := NULLIF(btrim(p_patch->>'photo_path'), '');
    IF v_photo_path IS NOT NULL
       AND v_photo_path !~ ('^caregiver-media/' || v_caregiver.id::text || '/[^/]+$') THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'photo path is not owned by caregiver';
    END IF;
  END IF;

  UPDATE public.caregivers AS c
  SET name = CASE WHEN p_patch ? 'name' THEN NULLIF(btrim(p_patch->>'name'), '') ELSE c.name END,
      role = CASE WHEN p_patch ? 'role' THEN NULLIF(btrim(p_patch->>'role'), '') ELSE c.role END,
      category = CASE WHEN p_patch ? 'category' THEN NULLIF(btrim(p_patch->>'category'), '') ELSE c.category END,
      gender = CASE WHEN p_patch ? 'gender' THEN NULLIF(btrim(p_patch->>'gender'), '') ELSE c.gender END,
      age = CASE WHEN p_patch ? 'age' THEN (p_patch->>'age')::smallint ELSE c.age END,
      city = CASE WHEN p_patch ? 'city' THEN NULLIF(btrim(p_patch->>'city'), '') ELSE c.city END,
      area = CASE WHEN p_patch ? 'area' THEN NULLIF(btrim(p_patch->>'area'), '') ELSE c.area END,
      languages = CASE WHEN p_patch ? 'languages' THEN p_patch->'languages' ELSE c.languages END,
      description = CASE WHEN p_patch ? 'description' THEN NULLIF(btrim(p_patch->>'description'), '') ELSE c.description END,
      photo_path = CASE WHEN p_patch ? 'photo_path' THEN v_photo_path ELSE c.photo_path END,
      updated_at = now()
  WHERE c.id = v_caregiver.id
    AND c.user_id = v_uid
    AND c.is_active = true
  RETURNING c.* INTO v_caregiver;

  RETURN jsonb_build_object(
    'id', v_caregiver.id,
    'user_id', v_caregiver.user_id,
    'name', v_caregiver.name,
    'role', v_caregiver.role,
    'category', v_caregiver.category,
    'gender', v_caregiver.gender,
    'age', v_caregiver.age,
    'city', v_caregiver.city,
    'area', v_caregiver.area,
    'languages', v_caregiver.languages,
    'description', v_caregiver.description,
    'photo_path', v_caregiver.photo_path,
    'rating', v_caregiver.rating,
    'reviews_count', v_caregiver.reviews_count,
    'price_per_shift', v_caregiver.price_per_shift
  );
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'caregiver ownership denied';
END
$function$;

REVOKE ALL ON FUNCTION public.update_my_caregiver_profile(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_my_caregiver_profile(jsonb) TO authenticated;

CREATE FUNCTION public.get_assigned_customer_details(p_booking_id uuid)
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
    'customer_id', cu.id,
    'customer_name', cu.customer_name,
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

-- Storage policy draft. Names are migration-owned; do not drop unknown policies.
CREATE POLICY caregiver_media_read_self
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'caregiver-media'
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND EXISTS (
    SELECT 1 FROM public.caregivers c
    WHERE c.id = (storage.foldername(name))[1]::uuid
      AND c.user_id = auth.uid()
      AND c.is_active = true
  )
);

CREATE POLICY caregiver_media_insert_self
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'caregiver-media'
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND EXISTS (
    SELECT 1 FROM public.caregivers c
    WHERE c.id = (storage.foldername(name))[1]::uuid
      AND c.user_id = auth.uid()
      AND c.is_active = true
  )
);

CREATE POLICY caregiver_media_update_self
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'caregiver-media'
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND EXISTS (
    SELECT 1 FROM public.caregivers c
    WHERE c.id = (storage.foldername(name))[1]::uuid
      AND c.user_id = auth.uid()
      AND c.is_active = true
  )
)
WITH CHECK (
  bucket_id = 'caregiver-media'
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND EXISTS (
    SELECT 1 FROM public.caregivers c
    WHERE c.id = (storage.foldername(name))[1]::uuid
      AND c.user_id = auth.uid()
      AND c.is_active = true
  )
);

CREATE POLICY caregiver_media_delete_self
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'caregiver-media'
  AND (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  AND EXISTS (
    SELECT 1 FROM public.caregivers c
    WHERE c.id = (storage.foldername(name))[1]::uuid
      AND c.user_id = auth.uid()
      AND c.is_active = true
  )
);

COMMIT;
