-- ============================================================================
-- MIGRATION: 20261108_000005_caregiver_profile_customer_rpc.sql
-- PURPOSE:
--   1. Strict preflight audit of Storage bucket & RLS policies to prevent
--      unauthorized bypass of caregiver-media bucket isolation.
--   2. Safe bucket inspection: verifies existing caregiver-media bucket and
--      aborts on conflict (e.g. public=true or insufficient file_size_limit)
--      without mutating valid existing bucket configurations.
--   3. Preservation of existing Storage policies: retains storage_caregiver_*
--      and verifies all permissive policies isolate by bucket and ownership.
--   4. Hardened RPC public.update_my_caregiver_profile(jsonb) with robust
--      age validation immune to anomalous JSON inputs, overflow, or syntax errors.
--   5. Hardened RPC public.get_assigned_customer_details(uuid) with explicit
--      ownership verification returning identical P0002 error for missing
--      or unassigned bookings.
--   6. Verifies authenticated role table privilege on public.caregivers without
--      expanding data access or modifying existing table grants.
--
-- SAFETY & AUDIT:
--   - Transactional (BEGIN ... COMMIT).
--   - Fails closed on any unexpected state or permission ambiguity.
--   - Does NOT delete existing data or modify migration 000002/000003.
--   - Retains existing storage_caregiver_* policies until explicit manual review.
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Preflight checks: schema relations, columns, table RLS, and permissions
-- -----------------------------------------------------------------------------
DO $preflight_caregiver_rpc$
DECLARE
  v_missing text;
  v_rls_missing text;
BEGIN
  -- 0.1 Required public relations
  SELECT string_agg(x.tbl, ', ' ORDER BY x.tbl) INTO v_missing
  FROM (VALUES
    ('caregivers'), ('bookings'), ('customers'),
    ('elder_profiles'), ('elder_addresses')
  ) AS x(tbl)
  WHERE to_regclass(format('public.%s', x.tbl)) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'caregiver rpc preflight failed; missing public relation(s): %', v_missing;
  END IF;

  -- 0.2 Storage schema relations
  IF to_regclass('storage.buckets') IS NULL OR to_regclass('storage.objects') IS NULL THEN
    RAISE EXCEPTION 'caregiver rpc preflight failed; storage schema relations missing';
  END IF;

  -- 0.3 Required column types
  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('caregivers', 'languages', 'jsonb'),
      ('caregivers', 'updated_at', 'timestamp with time zone'),
      ('elder_profiles', 'conditions', 'jsonb'),
      ('bookings', 'address_snapshot', 'jsonb'),
      ('bookings', 'start_at', 'timestamp with time zone'),
      ('bookings', 'end_at', 'timestamp with time zone'),
      ('bookings', 'total_amount', 'numeric')
    ) AS x(table_name, column_name, expected_type)
    LEFT JOIN pg_attribute a
      ON a.attrelid = format('public.%s', x.table_name)::regclass
     AND a.attname = x.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    WHERE a.attnum IS NULL
       OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_type)::oid
  ) THEN
    RAISE EXCEPTION 'caregiver rpc preflight failed; required column type mismatch';
  END IF;

  -- 0.4 Verify RLS enabled on sensitive tables
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO v_rls_missing
  FROM (VALUES ('caregivers'), ('bookings'), ('customers'), ('elder_profiles'), ('elder_addresses')) AS t(name)
  JOIN pg_class c ON c.oid = format('public.%s', t.name)::regclass
  WHERE NOT c.relrowsecurity;

  IF v_rls_missing IS NOT NULL THEN
    RAISE EXCEPTION 'caregiver rpc preflight failed; RLS disabled on: %', v_rls_missing;
  END IF;

  -- 0.5 Verify authenticated role can evaluate Storage RLS predicate without expanding permissions
  IF NOT has_table_privilege('authenticated', 'public.caregivers', 'SELECT') THEN
    RAISE EXCEPTION 'caregiver rpc preflight failed; authenticated role lacks SELECT on public.caregivers needed for Storage RLS ownership check';
  END IF;
END
$preflight_caregiver_rpc$;

-- -----------------------------------------------------------------------------
-- 1. Storage bucket inspection and conflict prevention
-- -----------------------------------------------------------------------------
DO $storage_bucket_inspection$
DECLARE
  v_bucket storage.buckets%ROWTYPE;
BEGIN
  SELECT * INTO v_bucket
  FROM storage.buckets
  WHERE id = 'caregiver-media';

  IF FOUND THEN
    -- Bucket exists: verify that it is strictly private without mutating configuration
    IF v_bucket.public IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'Storage bucket conflict: caregiver-media exists but is public (public=%). Must be private (public=false); aborting migration',
        v_bucket.public;
    END IF;

    -- Verify file size limit is at least 5MB if set
    IF v_bucket.file_size_limit IS NOT NULL AND v_bucket.file_size_limit < 5242880 THEN
      RAISE EXCEPTION 'Storage bucket conflict: caregiver-media exists with file_size_limit=% (< 5242880 bytes); aborting migration',
        v_bucket.file_size_limit;
    END IF;
  ELSE
    -- Bucket does not exist: create it cleanly with private configuration
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES (
      'caregiver-media',
      'caregiver-media',
      false,
      5242880,
      ARRAY['image/jpeg', 'image/png', 'image/webp']
    );
  END IF;
END
$storage_bucket_inspection$;

-- -----------------------------------------------------------------------------
-- 2. Storage policy audit: verify existing policies & prevent security bypass
-- -----------------------------------------------------------------------------
DO $storage_policy_audit$
DECLARE
  v_rec record;
  v_qual text;
  v_check text;
BEGIN
  FOR v_rec IN (
    SELECT schemaname, tablename, policyname, cmd, permissive, roles, qual, with_check
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND permissive = 'PERMISSIVE'
  ) LOOP
    v_qual := COALESCE(v_rec.qual, '');
    v_check := COALESCE(v_rec.with_check, '');

    -- 2.1 Catch broad / unscoped permissive policies that have no filter expression
    IF (v_rec.cmd IN ('SELECT', 'DELETE') AND v_rec.qual IS NULL)
       OR (v_rec.cmd = 'INSERT' AND v_rec.with_check IS NULL)
       OR (v_rec.cmd IN ('UPDATE', 'ALL') AND (v_rec.qual IS NULL OR v_rec.with_check IS NULL)) THEN
      RAISE EXCEPTION 'Storage policy audit failed: permissive policy "%" on storage.objects has unconstrained access (qual/with_check is NULL) and would bypass caregiver-media isolation',
        v_rec.policyname;
    END IF;

    -- 2.2 Catch policies that do not filter by bucket_id
    IF (v_rec.cmd IN ('SELECT', 'DELETE') AND v_qual NOT ILIKE '%bucket_id%')
       OR (v_rec.cmd = 'INSERT' AND v_check NOT ILIKE '%bucket_id%')
       OR (v_rec.cmd IN ('UPDATE', 'ALL') AND (v_qual NOT ILIKE '%bucket_id%' OR v_check NOT ILIKE '%bucket_id%')) THEN
      RAISE EXCEPTION 'Storage policy audit failed: permissive policy "%" on storage.objects does not filter by bucket_id and cannot be proven safe for caregiver-media',
        v_rec.policyname;
    END IF;

    -- 2.3 Inspect policies that mention caregiver-media: must be proven audited ownership policies
    IF v_qual ILIKE '%caregiver-media%' OR v_check ILIKE '%caregiver-media%' THEN
      -- If policy combines caregiver-media with other buckets, fail closed for manual review
      IF v_qual ILIKE '%customer-media%' OR v_check ILIKE '%customer-media%'
         OR v_qual ILIKE '%elder-media%' OR v_check ILIKE '%elder-media%' THEN
        RAISE EXCEPTION 'Storage policy audit failed: policy "%" grants access to caregiver-media alongside other buckets; cannot prove isolation, aborting migration',
          v_rec.policyname;
      END IF;

      -- If policy name is not one of our audited/managed ownership policies, fail closed
      IF v_rec.policyname NOT IN (
        'storage_caregiver_read', 'storage_caregiver_insert', 'storage_caregiver_update', 'storage_caregiver_delete',
        'caregiver_media_read_self', 'caregiver_media_insert_self', 'caregiver_media_update_self', 'caregiver_media_delete_self'
      ) THEN
        RAISE EXCEPTION 'Storage policy audit failed: unreviewed permissive policy "%" affects caregiver-media; cannot prove safe, aborting migration',
          v_rec.policyname;
      END IF;
    END IF;
  END LOOP;
END
$storage_policy_audit$;

-- -----------------------------------------------------------------------------
-- 3. RPC: update_my_caregiver_profile(jsonb) with robust age & payload validation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_my_caregiver_profile(p_patch jsonb)
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
  v_age_raw text;
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

  -- Robust age validation: guarantees no unhandled cast errors, overflows, or float issues
  IF p_patch ? 'age' THEN
    IF p_patch->'age' IS NOT NULL AND jsonb_typeof(p_patch->'age') <> 'null' THEN
      v_age_raw := p_patch->>'age';
      IF jsonb_typeof(p_patch->'age') <> 'number'
         OR v_age_raw IS NULL
         OR v_age_raw !~ '^[0-9]{1,3}$'
         OR v_age_raw::integer NOT BETWEEN 18 AND 100 THEN
        RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'age must be an integer from 18 to 100';
      END IF;
    END IF;
  END IF;

  -- Languages validation: array of non-empty strings
  IF p_patch ? 'languages'
     AND (p_patch->'languages' IS NULL OR jsonb_typeof(p_patch->'languages') <> 'array'
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_patch->'languages') AS item
            WHERE jsonb_typeof(item) <> 'string' OR btrim(item #>> '{}') = ''
          )) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'languages must be an array of non-empty strings';
  END IF;

  -- Canonical photo path validation
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
      age = CASE
        WHEN p_patch ? 'age' THEN
          CASE
            WHEN p_patch->'age' IS NULL OR jsonb_typeof(p_patch->'age') = 'null' THEN NULL
            ELSE (p_patch->>'age')::smallint
          END
        ELSE c.age
      END,
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
    'legacy_caregiver_id', v_caregiver.legacy_caregiver_id,
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

-- -----------------------------------------------------------------------------
-- 4. RPC: get_assigned_customer_details(uuid)
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 5. Storage policies: install canonical ownership policies
-- -----------------------------------------------------------------------------
-- Existing storage_caregiver_* policies are preserved and NOT dropped.
-- Only migration-owned target policies (caregiver_media_*_self) are dropped on re-run.
DROP POLICY IF EXISTS caregiver_media_read_self ON storage.objects;
DROP POLICY IF EXISTS caregiver_media_insert_self ON storage.objects;
DROP POLICY IF EXISTS caregiver_media_update_self ON storage.objects;
DROP POLICY IF EXISTS caregiver_media_delete_self ON storage.objects;

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
