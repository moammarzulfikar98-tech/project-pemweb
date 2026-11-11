-- ============================================================================
-- MIGRATION: 20261104_000002_customer_authenticated_booking.sql
-- PURPOSE:
-- 1. Create/validate public.customer_booking_requests for authenticated idempotency.
-- 2. Preserve caregiver SELECT access while adding authenticated customer SELECT.
-- 3. Remove direct client INSERT on public.bookings; booking writes use RPC only.
-- 4. Schema-qualify public.validate_booking_links() safely.
-- 5. Create RPC public.create_customer_booking (21 parameters).
--
-- DEPENDENCIES:
-- - 20261103_000001_initial_schema.sql
-- - 20261104_000001_guest_booking_elder_age.sql
-- - supabase/stepA_customer_name.sql
-- - supabase/guest_booking_design.sql (guest table + anonymous RPC contract)
--
-- SAFETY:
-- - Replaces both booking RPC pricing paths with one server-side contract.
-- - Preserves existing booking SELECT policies and bookings_no_overlap constraint.
-- - Derives pricing server-side from public.caregivers.price_per_shift.
-- - Binds customer_id strictly to auth.uid() (no frontend spoofing).
-- - Requires signup-provisioned profile + customer role; this RPC never self-elevates.
-- - Restricts customer SELECT to own bookings only.
-- - Revokes direct INSERT for PUBLIC, anon, and authenticated; caregiver SELECT remains.
-- - Existing policies are validated before conditional create/drop; unexpected state fails closed.
-- - Discount thresholds are exact 7/14/30 shifts, matching the current frontend.
-- - DESIGN ONLY: Review before running in Supabase SQL Editor.
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Production-schema and access preflight. Fail closed before changing objects.
-- -----------------------------------------------------------------------------
DO $preflight_schema$
DECLARE
  mismatch text;
  missing_default text;
  missing_constraint text;
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; auth.users is missing';
  END IF;

  -- Normalize the expected type through PostgreSQL's type catalog. Direct
  -- text comparison is unsafe for schema-qualified enum/composite names:
  -- format_type() may render the same OID with or without `public.` depending
  -- on context. Preserve numeric typmods explicitly because to_regtype()
  -- resolves the base type OID, not precision/scale.
  WITH expected AS (
    SELECT x.*,
           split_part(x.expected_type, '(', 1) AS expected_base_type,
           CASE
             WHEN strpos(x.expected_type, '(') > 0
               THEN substring(x.expected_type FROM strpos(x.expected_type, '('))
             ELSE ''
           END AS expected_typmod_suffix
    FROM (VALUES
      ('profiles', 'id', 'uuid', true),
      ('profiles', 'full_name', 'text', true),
      ('profiles', 'phone', 'text', false),
      ('profiles', 'created_at', 'timestamp with time zone', true),
      ('profiles', 'updated_at', 'timestamp with time zone', true),
      ('user_roles', 'user_id', 'uuid', true),
      ('user_roles', 'role', 'public.app_role', true),
      ('customers', 'id', 'uuid', true),
      ('customers', 'customer_name', 'text', false),
      ('customers', 'emergency_contact_name', 'text', true),
      ('customers', 'emergency_contact_phone', 'text', true),
      ('customers', 'created_at', 'timestamp with time zone', true),
      ('customers', 'updated_at', 'timestamp with time zone', true),
      ('elder_profiles', 'id', 'uuid', true),
      ('elder_profiles', 'customer_id', 'uuid', true),
      ('elder_profiles', 'name', 'text', true),
      ('elder_profiles', 'elder_age', 'integer', false),
      ('elder_profiles', 'gender', 'text', false),
      ('elder_profiles', 'conditions', 'jsonb', true),
      ('elder_profiles', 'allergies', 'text', false),
      ('elder_profiles', 'mobility', 'text', true),
      ('elder_profiles', 'medical_notes', 'text', false),
      ('elder_addresses', 'id', 'uuid', true),
      ('elder_addresses', 'elder_profile_id', 'uuid', true),
      ('elder_addresses', 'address_line', 'text', true),
      ('elder_addresses', 'city', 'text', true),
      ('elder_addresses', 'province', 'text', true),
      ('elder_addresses', 'postal_code', 'text', false),
      ('elder_addresses', 'latitude', 'numeric(9,6)', true),
      ('elder_addresses', 'longitude', 'numeric(9,6)', true),
      ('elder_addresses', 'access_notes', 'text', false),
      ('elder_addresses', 'is_default', 'boolean', true),
      ('caregivers', 'id', 'uuid', true),
      ('caregivers', 'price_per_shift', 'numeric(12,2)', true),
      ('caregivers', 'is_active', 'boolean', true),
      ('bookings', 'id', 'uuid', true),
      ('bookings', 'customer_id', 'uuid', true),
      ('bookings', 'caregiver_id', 'uuid', true),
      ('bookings', 'elder_profile_id', 'uuid', true),
      ('bookings', 'elder_address_id', 'uuid', true),
      ('bookings', 'start_at', 'timestamp with time zone', true),
      ('bookings', 'end_at', 'timestamp with time zone', true),
      ('bookings', 'status', 'public.booking_status', true),
      ('bookings', 'total_amount', 'numeric(12,2)', true),
      ('bookings', 'address_snapshot', 'jsonb', true)
    ) AS x(table_name, column_name, expected_type, expected_not_null)
  ), normalized AS (
    SELECT expected.*,
           format_type(to_regtype(expected_base_type)::oid, -1)
             || expected_typmod_suffix AS canonical_type
    FROM expected
  )
  SELECT string_agg(
           format(
             '%s.%s expected %s%s',
             x.table_name,
             x.column_name,
             x.expected_type,
             CASE WHEN x.expected_not_null THEN ' NOT NULL' ELSE ' NULLABLE' END
           ),
           ', ' ORDER BY x.table_name, x.column_name
         )
    INTO mismatch
  FROM normalized x
  LEFT JOIN pg_namespace n ON n.nspname = 'public'
  LEFT JOIN pg_class r ON r.relnamespace = n.oid
                       AND r.relname = x.table_name
                       AND r.relkind IN ('r', 'p')
  LEFT JOIN pg_attribute a ON a.attrelid = r.oid
                          AND a.attname = x.column_name
                          AND a.attnum > 0
                          AND NOT a.attisdropped
  WHERE a.attnum IS NULL
     OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_base_type)::oid
     OR format_type(a.atttypid, a.atttypmod) IS DISTINCT FROM x.canonical_type
     OR a.attnotnull IS DISTINCT FROM x.expected_not_null;

  IF mismatch IS NOT NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; schema mismatch: %', mismatch;
  END IF;

  SELECT string_agg(
           format('%s.%s default must contain %s', x.table_name, x.column_name, x.expected_fragment),
           ', ' ORDER BY x.table_name, x.column_name
         )
    INTO missing_default
  FROM (VALUES
    ('profiles', 'created_at', 'now()'),
    ('profiles', 'updated_at', 'now()'),
    ('user_roles', 'created_at', 'now()'),
    ('customers', 'created_at', 'now()'),
    ('customers', 'updated_at', 'now()'),
    ('elder_profiles', 'id', 'gen_random_uuid'),
    ('elder_profiles', 'created_at', 'now()'),
    ('elder_profiles', 'updated_at', 'now()'),
    ('elder_addresses', 'id', 'gen_random_uuid'),
    ('elder_addresses', 'created_at', 'now()'),
    ('bookings', 'id', 'gen_random_uuid'),
    ('bookings', 'created_at', 'now()'),
    ('bookings', 'updated_at', 'now()')
  ) AS x(table_name, column_name, expected_fragment)
  JOIN pg_class r ON r.relnamespace = 'public'::regnamespace
                 AND r.relname = x.table_name
  JOIN pg_attribute a ON a.attrelid = r.oid
                     AND a.attname = x.column_name
                     AND a.attnum > 0
                     AND NOT a.attisdropped
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE d.oid IS NULL
     OR lower(pg_get_expr(d.adbin, d.adrelid)) NOT LIKE '%' || lower(x.expected_fragment) || '%';

  IF missing_default IS NOT NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; missing/incompatible default: %', missing_default;
  END IF;

  -- Check FK semantics by source/target columns. Constraint names are not part
  -- of the contract because existing schemas may use composite foreign keys.
  WITH expected AS (
    SELECT *
    FROM (VALUES
      ('public.profiles', ARRAY['id']::text[], 'auth.users', ARRAY['id']::text[]),
      ('public.user_roles', ARRAY['user_id']::text[], 'public.profiles', ARRAY['id']::text[]),
      ('public.customers', ARRAY['id']::text[], 'public.profiles', ARRAY['id']::text[]),
      ('public.elder_profiles', ARRAY['customer_id']::text[], 'public.customers', ARRAY['id']::text[]),
      ('public.elder_addresses', ARRAY['elder_profile_id']::text[], 'public.elder_profiles', ARRAY['id']::text[]),
      ('public.bookings', ARRAY['customer_id']::text[], 'public.customers', ARRAY['id']::text[]),
      ('public.bookings', ARRAY['caregiver_id']::text[], 'public.caregivers', ARRAY['id']::text[]),
      ('public.bookings', ARRAY['elder_profile_id', 'customer_id']::text[], 'public.elder_profiles', ARRAY['id', 'customer_id']::text[]),
      ('public.bookings', ARRAY['elder_address_id', 'elder_profile_id']::text[], 'public.elder_addresses', ARRAY['id', 'elder_profile_id']::text[])
    ) AS x(source_table, source_columns, target_table, target_columns)
  ), missing AS (
    SELECT x.source_table, x.source_columns, x.target_table, x.target_columns
    FROM expected x
    WHERE NOT EXISTS (
      SELECT 1
      FROM pg_constraint c
      WHERE c.contype = 'f'
        AND c.conrelid = to_regclass(x.source_table)
        AND c.confrelid = to_regclass(x.target_table)
        AND c.conkey = ARRAY(
          SELECT a.attnum
          FROM pg_attribute a
          WHERE a.attrelid = c.conrelid
            AND a.attname = ANY (x.source_columns)
          ORDER BY array_position(x.source_columns, a.attname)
        )::smallint[]
        AND c.confkey = ARRAY(
          SELECT a.attnum
          FROM pg_attribute a
          WHERE a.attrelid = c.confrelid
            AND a.attname = ANY (x.target_columns)
          ORDER BY array_position(x.target_columns, a.attname)
        )::smallint[]
    )
  )
  SELECT string_agg(
           format('%s(%s) -> %s(%s) missing FK',
             source_table, array_to_string(source_columns, ','),
             target_table, array_to_string(target_columns, ',')),
           ', ' ORDER BY source_table, target_table
         )
    INTO missing_constraint
  FROM missing;

  IF missing_constraint IS NOT NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; missing foreign keys: %', missing_constraint;
  END IF;

  -- Check unique / primary key used by ON CONFLICT (id)
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    JOIN pg_attribute a ON a.attrelid = r.oid AND a.attname = 'id' AND a.attnum = ANY(c.conkey)
    WHERE n.nspname = 'public'
      AND r.relname = 'customers'
      AND c.contype IN ('p', 'u')
      AND c.conkey = ARRAY[a.attnum]::smallint[]
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; customers table missing primary/unique key on id';
  END IF;

  -- Existing customer_booking_requests must be exactly compatible before the
  -- later CREATE TABLE IF NOT EXISTS. Presence-only checks are insufficient:
  -- wrong types, nullability, FKs, defaults, or uniqueness can break atomic
  -- idempotency after deployment.
  IF to_regclass('public.customer_booking_requests') IS NOT NULL THEN
    WITH expected AS (
      SELECT x.*,
             split_part(x.expected_type, '(', 1) AS expected_base_type,
             CASE
               WHEN strpos(x.expected_type, '(') > 0
                 THEN substring(x.expected_type FROM strpos(x.expected_type, '('))
               ELSE ''
             END AS expected_typmod_suffix
      FROM (VALUES
        ('id', 'uuid', true),
        ('customer_user_id', 'uuid', true),
        ('idempotency_key', 'uuid', true),
        ('request_hash', 'text', true),
        ('booking_id', 'uuid', false),
        ('created_at', 'timestamp with time zone', true),
        ('completed_at', 'timestamp with time zone', false)
      ) AS x(column_name, expected_type, expected_not_null)
    ), normalized AS (
      SELECT expected.*,
             format_type(to_regtype(expected_base_type)::oid, -1)
               || expected_typmod_suffix AS canonical_type
      FROM expected
    )
    SELECT string_agg(
             format('customer_booking_requests.%s expected %s%s', x.column_name, x.expected_type,
               CASE WHEN x.expected_not_null THEN ' NOT NULL' ELSE ' NULLABLE' END),
             ', ' ORDER BY x.column_name
           )
      INTO mismatch
    FROM normalized x
    LEFT JOIN pg_attribute a
      ON a.attrelid = 'public.customer_booking_requests'::regclass
     AND a.attname = x.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    WHERE a.attnum IS NULL
       OR a.atttypid IS DISTINCT FROM to_regtype(x.expected_base_type)::oid
       OR format_type(a.atttypid, a.atttypmod) IS DISTINCT FROM x.canonical_type
       OR a.attnotnull IS DISTINCT FROM x.expected_not_null;

    IF mismatch IS NOT NULL THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests columns: %', mismatch;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM pg_attribute a
      WHERE a.attrelid = 'public.customer_booking_requests'::regclass
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.attname NOT IN ('id', 'customer_user_id', 'idempotency_key', 'request_hash', 'booking_id', 'created_at', 'completed_at')
        AND a.attnotnull
        AND NOT EXISTS (
          SELECT 1 FROM pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum
        )
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests has unsupported required columns';
    END IF;

    SELECT string_agg(
             format('customer_booking_requests.%s default must contain %s', x.column_name, x.expected_fragment),
             ', ' ORDER BY x.column_name
           )
      INTO mismatch
    FROM (VALUES
      ('id', 'gen_random_uuid'),
      ('created_at', 'now()')
    ) AS x(column_name, expected_fragment)
    JOIN pg_attribute a
      ON a.attrelid = 'public.customer_booking_requests'::regclass
     AND a.attname = x.column_name
     AND a.attnum > 0
     AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d
      ON d.adrelid = a.attrelid
     AND d.adnum = a.attnum
    WHERE d.oid IS NULL
       OR lower(pg_get_expr(d.adbin, d.adrelid)) NOT LIKE '%' || lower(x.expected_fragment) || '%';

    IF mismatch IS NOT NULL THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests defaults: %', mismatch;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.customer_booking_requests'::regclass
        AND c.contype = 'c'
        AND pg_get_constraintdef(c.oid) ILIKE '%request_hash%'
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests.request_hash check missing';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.customer_booking_requests'::regclass
        AND c.contype = 'p'
        AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'id')]::smallint[]
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests.id primary key missing';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.customer_booking_requests'::regclass
        AND c.contype IN ('u', 'p')
        AND c.conkey = ARRAY[
          (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'customer_user_id'),
          (SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'idempotency_key')
        ]::smallint[]
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests user/idempotency uniqueness missing';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.customer_booking_requests'::regclass
        AND c.contype = 'f'
        AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'customer_user_id')]::smallint[]
        AND c.confrelid = 'auth.users'::regclass
        AND c.confdeltype = 'c'
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests.customer_user_id FK missing';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.customer_booking_requests'::regclass
        AND c.contype = 'f'
        AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = c.conrelid AND attname = 'booking_id')]::smallint[]
        AND c.confrelid = 'public.bookings'::regclass
        AND c.confdeltype = 'r'
    ) THEN
      RAISE EXCEPTION 'authenticated booking preflight failed; customer_booking_requests.booking_id FK missing';
    END IF;
  END IF;

  -- Check extensions.digest availability
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; extensions.digest(bytea, text) missing';
  END IF;

  -- Check RLS is enabled on bookings
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class r
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'public'
      AND r.relname = 'bookings'
      AND r.relrowsecurity = true
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; public.bookings does not have RLS enabled';
  END IF;
END
$preflight_schema$;

DO $preflight_enums$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE t.typnamespace = 'public'::regnamespace
      AND t.typname = 'app_role'
      AND e.enumlabel = 'customer'
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; app_role.customer is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE t.typnamespace = 'public'::regnamespace
      AND t.typname = 'booking_status'
      AND e.enumlabel = 'pending'
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; booking_status.pending is missing';
  END IF;
END
$preflight_enums$;

DO $preflight_existing_objects$
BEGIN
  -- Check bookings_no_overlap exclusion constraint details
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE n.nspname = 'public'
      AND r.relname = 'bookings'
      AND c.conname = 'bookings_no_overlap'
      AND c.contype = 'x'
      AND pg_get_constraintdef(c.oid) ILIKE '%caregiver_id%'
      AND pg_get_constraintdef(c.oid) ILIKE '%start_at%'
      AND pg_get_constraintdef(c.oid) ILIKE '%end_at%'
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; bookings_no_overlap definition is missing or invalid';
  END IF;

  IF pg_catalog.to_regprocedure(
       'public.create_anonymous_booking(uuid,uuid,text,text,text,text,integer,text,jsonb,text,text,text,text,text,text,text,numeric,numeric,text,timestamp with time zone,timestamp with time zone)'
     ) IS NULL THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; existing create_anonymous_booking signature is missing';
  END IF;

  -- Verify create_anonymous_booking is SECURITY DEFINER
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'create_anonymous_booking'
      AND p.prosecdef = true
  ) THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; create_anonymous_booking is not SECURITY DEFINER';
  END IF;
END
$preflight_existing_objects$;

-- Verify that existing caregiver booking SELECT policy remains present.
DO $preflight_booking_policies$
DECLARE
  caregiver_policy_count integer;
BEGIN
  SELECT count(*)
    INTO caregiver_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'bookings'
    AND cmd IN ('SELECT', 'ALL')
    AND coalesce(qual, '') ILIKE '%caregiver_id%'
    AND coalesce(qual, '') ILIKE '%user_id%';

  IF caregiver_policy_count = 0 THEN
    RAISE EXCEPTION 'authenticated booking preflight failed; no existing caregiver-owned bookings SELECT policy found';
  END IF;
END
$preflight_booking_policies$;

-- 1. Repair the trigger function created by 000001. Every relation is
-- explicitly schema-qualified; the fixed search_path prevents shadowing.
CREATE OR REPLACE FUNCTION public.validate_booking_links()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_address public.elder_addresses;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.elder_profiles AS e
    WHERE e.id = NEW.elder_profile_id
      AND e.customer_id = NEW.customer_id
  ) THEN
    RAISE EXCEPTION 'elder/customer mismatch';
  END IF;

  SELECT address_row.*
    INTO v_address
  FROM public.elder_addresses AS address_row
  WHERE address_row.id = NEW.elder_address_id
    AND address_row.elder_profile_id = NEW.elder_profile_id;

  IF v_address.id IS NULL THEN
    RAISE EXCEPTION 'elder address mismatch';
  END IF;

  -- Server is source of truth; client address_snapshot is ignored.
  NEW.address_snapshot := jsonb_build_object(
    'address_line', v_address.address_line,
    'city', v_address.city,
    'province', v_address.province,
    'postal_code', v_address.postal_code,
    'latitude', v_address.latitude,
    'longitude', v_address.longitude,
    'access_notes', v_address.access_notes
  );
  RETURN NEW;
END;
$function$;

-- 2. Idempotency table for authenticated customers
CREATE TABLE IF NOT EXISTS public.customer_booking_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_user_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  idempotency_key uuid NOT NULL,
  request_hash text NOT NULL,
  booking_id uuid
    REFERENCES public.bookings(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  CONSTRAINT customer_booking_requests_hash_not_blank
    CHECK (btrim(request_hash) <> ''),
  CONSTRAINT customer_booking_requests_user_key_unique
    UNIQUE (customer_user_id, idempotency_key)
);

ALTER TABLE public.customer_booking_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.customer_booking_requests FROM PUBLIC, anon, authenticated;

-- 2. Policy/access transition. Never drop or replace an existing policy.
-- A same-name policy with a different definition is unsafe, so preflight fails.
DO $policy_preflight$
DECLARE
  v_policy record;
  v_expected_qual text := '(customer_id = auth.uid())';
BEGIN
  SELECT * INTO v_policy
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'bookings'
    AND policyname = 'customer_read_own_bookings_authenticated';

  IF FOUND THEN
    IF v_policy.cmd <> 'SELECT'
       OR v_policy.roles <> ARRAY['authenticated']::name[]
       OR regexp_replace(coalesce(v_policy.qual, ''), '\s+', '', 'g') <> regexp_replace(v_expected_qual, '\s+', '', 'g')
       OR coalesce(v_policy.with_check, '') <> '' THEN
      RAISE EXCEPTION 'authenticated booking policy preflight failed; existing customer_read_own_bookings_authenticated differs';
    END IF;
  ELSE
    EXECUTE 'CREATE POLICY customer_read_own_bookings_authenticated ON public.bookings FOR SELECT TO authenticated USING (customer_id = auth.uid())';
  END IF;
END;
$policy_preflight$;

-- Client INSERT is deliberately disabled. SECURITY DEFINER RPCs remain usable;
-- caregiver SELECT policy remains untouched and must already be present above.
REVOKE INSERT ON TABLE public.bookings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.bookings TO authenticated;

-- 3. RPC create_customer_booking
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
  p_end_at timestamptz
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
BEGIN
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
    'end_at', p_end_at
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

  UPDATE public.customer_booking_requests
  SET booking_id = v_booking_id, completed_at = now()
  WHERE id = v_existing_request.id;

  RETURN QUERY SELECT v_booking_id, v_booking_status, v_total_amount;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_customer_booking(
  uuid, uuid, text, text, text, text, integer, text, jsonb, text,
  text, text, text, text, text, text, numeric, numeric, text,
  timestamptz, timestamptz
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_customer_booking(
  uuid, uuid, text, text, text, text, integer, text, jsonb, text,
  text, text, text, text, text, text, numeric, numeric, text,
  timestamptz, timestamptz
) TO authenticated;

COMMIT;
