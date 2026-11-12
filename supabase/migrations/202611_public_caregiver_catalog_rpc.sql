-- Public caregiver catalog RPC. Review and run manually in Supabase SQL Editor.
-- Does not grant anon SELECT on public.caregivers.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_caregivers()
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'id', c.id,
    'legacy_caregiver_id', c.legacy_caregiver_id,
    'name', c.name,
    'role', c.role,
    'category', c.category,
    'gender', c.gender,
    'age', c.age,
    'city', c.city,
    'area', c.area,
    'languages', c.languages,
    'description', c.description,
    'price_per_shift', c.price_per_shift,
    'rating', c.rating,
    'reviews_count', c.reviews_count,
    'badge', c.badge,
    'photo_path', c.photo_path
  )
  FROM public.caregivers AS c
  WHERE c.is_active = true
  ORDER BY c.legacy_caregiver_id ASC;
$$;

REVOKE ALL ON FUNCTION public.get_public_caregivers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_caregivers() TO anon, authenticated;

COMMIT;
