-- READ-ONLY PRODUCTION PREFLIGHT. Do not modify this script to auto-fix.
-- Run manually in Supabase SQL Editor before executing
-- 202611_profile_customer_rpc.sql.
--
-- Results use PASS / FAIL / NEEDS MANUAL REVIEW.
-- Storage policy semantics cannot be proven from names or string matching alone;
-- every existing storage.objects policy is emitted for manual review.

-- 1. Consolidated machine-readable checks.
WITH checks AS (
  SELECT
    'bucket.caregiver-media.private'::text AS check_name,
    CASE WHEN EXISTS (
      SELECT 1 FROM storage.buckets b
      WHERE b.id = 'caregiver-media' AND b.public = false
    ) THEN 'PASS' ELSE 'FAIL' END AS status,
    CASE WHEN EXISTS (
      SELECT 1 FROM storage.buckets b
      WHERE b.id = 'caregiver-media' AND b.public = false
    ) THEN 'caregiver-media exists and public=false'
    ELSE 'bucket missing or public=true' END AS detail

  UNION ALL
  SELECT
    'rpc.update_my_caregiver_profile.collision',
    CASE WHEN to_regprocedure('public.update_my_caregiver_profile(jsonb)') IS NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.update_my_caregiver_profile(jsonb)') IS NULL
      THEN 'signature not present'
      ELSE 'signature already exists' END

  UNION ALL
  SELECT
    'rpc.get_assigned_customer_details.collision',
    CASE WHEN to_regprocedure('public.get_assigned_customer_details(uuid)') IS NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.get_assigned_customer_details(uuid)') IS NULL
      THEN 'signature not present'
      ELSE 'signature already exists' END

  UNION ALL
  SELECT
    'rls.' || x.relname,
    CASE
      WHEN c.oid IS NULL THEN 'FAIL'
      WHEN c.relrowsecurity THEN 'PASS'
      ELSE 'FAIL'
    END,
    CASE
      WHEN c.oid IS NULL THEN 'relation missing'
      ELSE format('relrowsecurity=%s relforcerowsecurity=%s', c.relrowsecurity, c.relforcerowsecurity)
    END
  FROM (VALUES
    ('public.caregivers'),
    ('public.bookings'),
    ('public.customers'),
    ('public.elder_profiles'),
    ('public.elder_addresses')
  ) AS x(relname)
  LEFT JOIN pg_class c ON c.oid = to_regclass(x.relname)

  UNION ALL
  SELECT
    'columns.required.types',
    CASE WHEN NOT EXISTS (
      SELECT 1
      FROM (VALUES
        ('public.caregivers', 'languages', 'jsonb', NULL::integer, NULL::integer),
        ('public.caregivers', 'updated_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.elder_profiles', 'conditions', 'jsonb', NULL::integer, NULL::integer),
        ('public.bookings', 'address_snapshot', 'jsonb', NULL::integer, NULL::integer),
        ('public.bookings', 'start_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.bookings', 'end_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.bookings', 'total_amount', 'numeric', 12, 2)
      ) AS x(relname, col, expected_base_type, expected_precision, expected_scale)
      LEFT JOIN pg_attribute a
        ON a.attrelid = to_regclass(x.relname)
       AND a.attname = x.col
       AND a.attnum > 0 AND NOT a.attisdropped
      WHERE a.attnum IS NULL
         OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_base_type)::oid
         OR (x.expected_base_type = 'numeric'
             AND (a.atttypmod - 4) IS DISTINCT FROM
                 ((x.expected_precision << 16) + x.expected_scale))
    ) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT EXISTS (
      SELECT 1
      FROM (VALUES
        ('public.caregivers', 'languages', 'jsonb', NULL::integer, NULL::integer),
        ('public.caregivers', 'updated_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.elder_profiles', 'conditions', 'jsonb', NULL::integer, NULL::integer),
        ('public.bookings', 'address_snapshot', 'jsonb', NULL::integer, NULL::integer),
        ('public.bookings', 'start_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.bookings', 'end_at', 'timestamp with time zone', NULL::integer, NULL::integer),
        ('public.bookings', 'total_amount', 'numeric', 12, 2)
      ) AS x(relname, col, expected_base_type, expected_precision, expected_scale)
      LEFT JOIN pg_attribute a
        ON a.attrelid = to_regclass(x.relname)
       AND a.attname = x.col
       AND a.attnum > 0 AND NOT a.attisdropped
      WHERE a.attnum IS NULL
         OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_base_type)::oid
         OR (x.expected_base_type = 'numeric'
             AND (a.atttypmod - 4) IS DISTINCT FROM
                 ((x.expected_precision << 16) + x.expected_scale))
    ) THEN 'all required base types match; numeric typmod is precision=12 scale=2'
    ELSE 'one or more required columns/base types/numeric typmods mismatch' END

  UNION ALL
  SELECT
    'privilege.current_user.public.caregivers',
    'NEEDS MANUAL REVIEW',
    format('SQL editor role=%s; SELECT=%s UPDATE=%s; authenticated runtime remains unverified',
      current_user,
      has_table_privilege(current_user, 'public.caregivers', 'SELECT'),
      has_table_privilege(current_user, 'public.caregivers', 'UPDATE'))

  UNION ALL
  SELECT
    'privilege.current_user.storage.objects',
    'NEEDS MANUAL REVIEW',
    format('SQL editor role=%s; SELECT=%s INSERT=%s UPDATE=%s DELETE=%s; authenticated runtime remains unverified',
      current_user,
      has_table_privilege(current_user, 'storage.objects', 'SELECT'),
      has_table_privilege(current_user, 'storage.objects', 'INSERT'),
      has_table_privilege(current_user, 'storage.objects', 'UPDATE'),
      has_table_privilege(current_user, 'storage.objects', 'DELETE'))
)
SELECT check_name, status, detail
FROM checks
ORDER BY check_name;

-- 2. Exact existing Storage policy inventory. Review every row.
SELECT
  p.policyname,
  p.cmd,
  p.permissive,
  p.roles,
  p.qual,
  p.with_check,
  CASE
    WHEN p.qual IS NULL AND p.cmd IN ('SELECT', 'DELETE', 'UPDATE', 'ALL')
      THEN 'NEEDS MANUAL REVIEW: broad/missing USING expression'
    WHEN p.with_check IS NULL AND p.cmd IN ('INSERT', 'UPDATE', 'ALL')
      THEN 'NEEDS MANUAL REVIEW: broad/missing WITH CHECK expression'
    WHEN p.qual ILIKE '%caregiver-media%'
      OR p.with_check ILIKE '%caregiver-media%'
      THEN 'NEEDS MANUAL REVIEW: expression mentions caregiver-media; verify ownership semantics'
    ELSE 'NEEDS MANUAL REVIEW: policy expression may be dynamic; inspect full expression'
  END AS review_status
FROM pg_policies p
WHERE p.schemaname = 'storage'
  AND p.tablename = 'objects'
ORDER BY p.policyname, p.cmd;

-- 3. Collision check for all four policy names.
SELECT
  target.policyname,
  CASE WHEN p.policyname IS NULL THEN 'PASS' ELSE 'FAIL' END AS status,
  CASE WHEN p.policyname IS NULL THEN 'name available' ELSE 'policy already exists' END AS detail
FROM (VALUES
  ('caregiver_media_read_self'),
  ('caregiver_media_insert_self'),
  ('caregiver_media_update_self'),
  ('caregiver_media_delete_self')
) AS target(policyname)
LEFT JOIN pg_policies p
  ON p.schemaname = 'storage'
 AND p.tablename = 'objects'
 AND p.policyname = target.policyname
ORDER BY target.policyname;

-- 4. Function inventory: all overloads with either target name.
SELECT
  n.nspname AS schema_name,
  p.oid::regprocedure AS signature,
  p.prosecdef AS security_definer,
  pg_get_userbyid(p.proowner) AS owner,
  p.proacl AS acl,
  pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('update_my_caregiver_profile', 'get_assigned_customer_details')
ORDER BY p.proname, p.oid::regprocedure::text;

-- 5. Relevant table policies and privileges. This is inventory, not proof of
-- SECURITY DEFINER behavior; the RPC body still requires manual review.
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('caregivers', 'bookings', 'customers', 'elder_profiles', 'elder_addresses')
ORDER BY tablename, policyname, cmd;

SELECT
  relname AS table_name,
  relrowsecurity,
  relforcerowsecurity
FROM pg_class
WHERE oid IN (
  'public.caregivers'::regclass,
  'public.bookings'::regclass,
  'public.customers'::regclass,
  'public.elder_profiles'::regclass,
  'public.elder_addresses'::regclass,
  'storage.objects'::regclass
)
ORDER BY relname;

-- 6. Exact required-column inventory for manual comparison.
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  a.attname AS column_name,
  format_type(a.atttypid, a.atttypmod) AS displayed_type,
  t.typnamespace::regnamespace::text AS type_schema,
  t.typname AS type_name,
  NOT a.attnotnull AS nullable,
  pg_get_expr(d.adbin, d.adrelid) AS default_expression
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE a.attnum > 0
  AND NOT a.attisdropped
  AND (
    (n.nspname = 'public' AND c.relname IN ('caregivers','bookings','customers','elder_profiles','elder_addresses'))
    OR (n.nspname = 'storage' AND c.relname = 'objects')
  )
ORDER BY n.nspname, c.relname, a.attnum;

-- 7. Manual decision rule:
--    STOP if any consolidated check is FAIL.
--    STOP if any collision row is FAIL.
--    STOP for manual review if any Storage policy row is not understood and
--    explicitly proven not to grant access to caregiver-media.
--    A SQL result cannot certify dynamic policy semantics automatically.
