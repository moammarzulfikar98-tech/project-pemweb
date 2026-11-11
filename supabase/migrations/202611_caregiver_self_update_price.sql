-- ============================================================================
-- MIGRATION: 202611_caregiver_self_update_price.sql
-- PURPOSE:
--   Allow caregivers to update price_per_shift on their own record via
--   public.update_my_caregiver_profile(jsonb).
-- SECURITY & CONSTRAINTS:
--   - Caregiver owns record: c.user_id = auth.uid() AND c.is_active = true.
--   - Validation: price_per_shift numeric >= 0.
--   - Protected: is_active cannot be modified by caregiver.
--   - Protected: UUID and legacy_caregiver_id cannot be modified.
-- STATUS:
--   REVIEW ARTIFACT ONLY. Do NOT execute without explicit user approval.
-- ============================================================================

BEGIN;

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

  -- Allowlist includes price_per_shift alongside operational profile fields
  SELECT string_agg(key, ', ' ORDER BY key)
    INTO v_unknown
  FROM unnest(v_keys) AS key
  WHERE key NOT IN (
    'name', 'role', 'category', 'gender', 'age', 'city', 'area',
    'languages', 'description', 'photo_path', 'price_per_shift'
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

  -- Validate age
  IF p_patch ? 'age'
     AND (p_patch->'age' IS NULL OR jsonb_typeof(p_patch->'age') <> 'number'
          OR (p_patch->>'age')::numeric <> trunc((p_patch->>'age')::numeric)
          OR (p_patch->>'age')::integer NOT BETWEEN 18 AND 100) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'age must be an integer from 18 to 100';
  END IF;

  -- Validate price_per_shift
  IF p_patch ? 'price_per_shift'
     AND (p_patch->'price_per_shift' IS NULL OR jsonb_typeof(p_patch->'price_per_shift') <> 'number'
          OR (p_patch->>'price_per_shift')::numeric < 0) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'price_per_shift must be a non-negative number';
  END IF;

  -- Validate languages
  IF p_patch ? 'languages'
     AND (p_patch->'languages' IS NULL OR jsonb_typeof(p_patch->'languages') <> 'array'
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_patch->'languages') AS item
            WHERE jsonb_typeof(item) <> 'string' OR btrim(item #>> '{}') = ''
          )) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0003', MESSAGE = 'languages must be an array of non-empty strings';
  END IF;

  -- Validate photo_path ownership
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
      price_per_shift = CASE WHEN p_patch ? 'price_per_shift' THEN (p_patch->>'price_per_shift')::numeric(12,2) ELSE c.price_per_shift END,
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
END;
$function$;

REVOKE ALL ON FUNCTION public.update_my_caregiver_profile(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_my_caregiver_profile(jsonb) TO authenticated;

COMMIT;
