-- ============================================================================
-- MIGRATION: 20261104_000003_customer_auth_trigger.sql
-- PURPOSE:
--   Preserve existing public.handle_auth_user_profile() for profile
--   provisioning, then add one separate auth.users trigger for customer-role
--   provisioning. Existing-account repair is out of scope for this migration.
--   A server-managed marker bypasses customer-role provisioning for trusted
--   admin/caregiver creation; that path provisions its own role.
--
-- SAFETY:
--   - DESIGN/REVIEW DRAFT ONLY. Do not execute without separate user approval.
--   - Does not trust raw_user_meta_data.role.
--   - Uses auth.users.is_anonymous as the canonical anonymous-user guard.
--   - Uses only the server-managed app_metadata provisioning marker to bypass
--     customer provisioning for trusted admin/caregiver account creation.
--   - Does not depend on 000002 at DDL time; filename order may apply 000002
--     first. Authenticated booking is gated until both migrations succeed.
--   - Creates no public.customers row; that remains atomic in 000002 booking RPC.
--   - Existing-account repair is kept in 20261107_000004; that repair inserts
--     only missing profiles/roles and never overwrites or deletes existing data.
--   - Requires the reviewed existing trigger/function surface and fails closed
--     when another auth.users trigger is present.
--   - Replaces only handle_auth_user_profile() after exact preflight; it keeps
--     on_auth_user_created_profile and does not create a second trigger.
-- ============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. Preflight. Every failure aborts the transaction before function/trigger DDL.
-- -----------------------------------------------------------------------------
DO $preflight_customer_auth$
DECLARE
  v_missing text;
  v_mismatch text;
  v_missing_default text;
  v_missing_constraint text;
  v_existing_triggers text;
  v_rls_problem text;
  v_extra_required text;
BEGIN
  -- Required relations.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'auth'
      AND c.relname = 'users'
      AND c.relkind IN ('r', 'p')
  ) THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; auth.users table is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('profiles', 'user_roles')
      AND c.relkind IN ('r', 'p')
    GROUP BY n.nspname
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; public.profiles or public.user_roles is missing';
  END IF;

  -- Required auth identity columns. is_anonymous is trusted auth state;
  -- raw_user_meta_data is used only for display/contact fields.
  SELECT string_agg(
           format('auth.users.%s expected %s', x.column_name, x.expected_type),
           ', ' ORDER BY x.column_name
         )
    INTO v_missing
  FROM (VALUES
    ('id', 'uuid'),
    -- Supabase auth.users.email is normally varchar without a typmod.
    -- Compare canonical base type, not an assumed varchar length.
    ('email', 'character varying'),
    ('is_anonymous', 'boolean'),
    ('raw_app_meta_data', 'jsonb'),
    ('raw_user_meta_data', 'jsonb')
  ) AS x(column_name, expected_type)
  LEFT JOIN pg_attribute a
    ON a.attrelid = 'auth.users'::regclass
   AND a.attname = x.column_name
   AND a.attnum > 0
   AND NOT a.attisdropped
  WHERE a.attnum IS NULL
     OR format_type(a.atttypid, a.atttypmod) <> x.expected_type;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; auth.users columns: %', v_missing;
  END IF;

  -- Required public columns, types, and nullability.
  SELECT string_agg(
           format(
             'public.%s.%s expected %s%s',
             x.table_name,
             x.column_name,
             x.expected_type,
             CASE WHEN x.expected_not_null THEN ' NOT NULL' ELSE ' NULLABLE' END
           ),
           ', ' ORDER BY x.table_name, x.column_name
         )
    INTO v_mismatch
  FROM (VALUES
    ('profiles', 'id', 'uuid', true),
    ('profiles', 'full_name', 'text', true),
    ('profiles', 'phone', 'text', false),
    ('profiles', 'created_at', 'timestamp with time zone', true),
    ('profiles', 'updated_at', 'timestamp with time zone', true),
    ('user_roles', 'user_id', 'uuid', true),
    ('user_roles', 'role', 'public.app_role', true),
    ('user_roles', 'created_at', 'timestamp with time zone', true)
  ) AS x(table_name, column_name, expected_type, expected_not_null)
  LEFT JOIN pg_attribute a
    ON a.attrelid = to_regclass(format('public.%s', x.table_name))
   AND a.attname = x.column_name
   AND a.attnum > 0
   AND NOT a.attisdropped
  WHERE a.attnum IS NULL
     OR format_type(a.atttypid, a.atttypmod) <> x.expected_type
     OR a.attnotnull IS DISTINCT FROM x.expected_not_null;

  IF v_mismatch IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; public schema mismatch: %', v_mismatch;
  END IF;

  -- The trigger omits timestamp columns, so their defaults must exist.
  SELECT string_agg(
           format('public.%s.%s requires a now()/current_timestamp default', x.table_name, x.column_name),
           ', ' ORDER BY x.table_name, x.column_name
         )
    INTO v_missing_default
  FROM (VALUES
    ('profiles', 'created_at'),
    ('profiles', 'updated_at'),
    ('user_roles', 'created_at')
  ) AS x(table_name, column_name)
  JOIN pg_attribute a
    ON a.attrelid = to_regclass(format('public.%s', x.table_name))
   AND a.attname = x.column_name
   AND a.attnum > 0
   AND NOT a.attisdropped
  LEFT JOIN pg_attrdef d
    ON d.adrelid = a.attrelid
   AND d.adnum = a.attnum
  WHERE d.oid IS NULL
     OR (
       lower(pg_get_expr(d.adbin, d.adrelid)) NOT LIKE '%now()%'
       AND lower(pg_get_expr(d.adbin, d.adrelid)) NOT LIKE '%current_timestamp%'
     );

  IF v_missing_default IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; defaults: %', v_missing_default;
  END IF;

  -- No additional required column may make the two trigger inserts fail.
  SELECT string_agg(
           format('public.%s.%s has no default and is not supplied by trigger', r.relname, a.attname),
           ', ' ORDER BY r.relname, a.attname
         )
    INTO v_extra_required
  FROM pg_class r
  JOIN pg_namespace n ON n.oid = r.relnamespace
  JOIN pg_attribute a ON a.attrelid = r.oid
                      AND a.attnum > 0
                      AND NOT a.attisdropped
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE n.nspname = 'public'
    AND r.relname IN ('profiles', 'user_roles')
    AND a.attnotnull
    AND d.oid IS NULL
    AND NOT (
      (r.relname = 'profiles' AND a.attname IN ('id', 'full_name', 'phone'))
      OR (r.relname = 'user_roles' AND a.attname IN ('user_id', 'role'))
    );

  IF v_extra_required IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; unsupported required columns: %', v_extra_required;
  END IF;

  -- app_role must contain every fixed label used by this function. Other
  -- labels, if any, are left untouched so existing role data is preserved.
  SELECT string_agg(x.role_name, ', ' ORDER BY x.role_name)
    INTO v_missing
  FROM (VALUES ('customer'), ('caregiver'), ('admin')) AS x(role_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE n.nspname = 'public'
      AND t.typname = 'app_role'
      AND t.typtype = 'e'
      AND e.enumlabel = x.role_name
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; public.app_role labels missing: %', v_missing;
  END IF;

  -- Required keys and foreign keys. Constraint names are deliberately not
  -- assumed; semantics are checked instead.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.profiles'::regclass
      AND c.contype = 'p'
      AND c.conkey = ARRAY[(
        SELECT a.attnum
        FROM pg_attribute a
        WHERE a.attrelid = 'public.profiles'::regclass
          AND a.attname = 'id'
      )]::smallint[]
  ) THEN
    v_missing_constraint := concat_ws(', ', v_missing_constraint, 'profiles(id) primary key');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.profiles'::regclass
      AND c.confrelid = 'auth.users'::regclass
      AND c.contype = 'f'
      AND c.conkey = ARRAY[(
        SELECT a.attnum
        FROM pg_attribute a
        WHERE a.attrelid = 'public.profiles'::regclass
          AND a.attname = 'id'
      )]::smallint[]
      AND c.confkey = ARRAY[(
        SELECT a.attnum
        FROM pg_attribute a
        WHERE a.attrelid = 'auth.users'::regclass
          AND a.attname = 'id'
      )]::smallint[]
      AND c.confdeltype = 'c'
  ) THEN
    v_missing_constraint := concat_ws(', ', v_missing_constraint, 'profiles.id -> auth.users.id ON DELETE CASCADE');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.user_roles'::regclass
      AND c.contype = 'p'
      AND c.conkey = ARRAY[
        (SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = 'public.user_roles'::regclass AND a.attname = 'user_id'),
        (SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = 'public.user_roles'::regclass AND a.attname = 'role')
      ]::smallint[]
  ) THEN
    v_missing_constraint := concat_ws(', ', v_missing_constraint, 'user_roles(user_id, role) primary key');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.user_roles'::regclass
      AND c.confrelid = 'public.profiles'::regclass
      AND c.contype = 'f'
      AND c.conkey = ARRAY[(
        SELECT a.attnum
        FROM pg_attribute a
        WHERE a.attrelid = 'public.user_roles'::regclass
          AND a.attname = 'user_id'
      )]::smallint[]
      AND c.confkey = ARRAY[(
        SELECT a.attnum
        FROM pg_attribute a
        WHERE a.attrelid = 'public.profiles'::regclass
          AND a.attname = 'id'
      )]::smallint[]
      AND c.confdeltype = 'c'
  ) THEN
    v_missing_constraint := concat_ws(', ', v_missing_constraint, 'user_roles.user_id -> profiles.id ON DELETE CASCADE');
  END IF;

  IF v_missing_constraint IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; constraints: %', v_missing_constraint;
  END IF;

  -- RLS must remain active; FORCE ROW LEVEL SECURITY would also apply to the
  -- SECURITY DEFINER owner and can make provisioning fail unexpectedly.
  SELECT string_agg(r.relname, ', ' ORDER BY r.relname)
    INTO v_rls_problem
  FROM pg_class r
  JOIN pg_namespace n ON n.oid = r.relnamespace
  WHERE n.nspname = 'public'
    AND r.relname IN ('profiles', 'user_roles')
    AND (NOT r.relrowsecurity OR r.relforcerowsecurity);

  IF v_rls_problem IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; RLS must be enabled and not forced on: %', v_rls_problem;
  END IF;

  -- The migration executor becomes the SECURITY DEFINER owner. Verify it can
  -- perform the inserts before creating the function.
  IF NOT pg_catalog.has_table_privilege(current_user, 'public.profiles', 'INSERT')
     OR NOT pg_catalog.has_table_privilege(current_user, 'public.user_roles', 'INSERT') THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; executor lacks INSERT privilege on provisioning tables';
  END IF;

  -- Preserve the audited profile trigger. Do not drop, replace, or create
  -- another profile trigger. Any unknown auth.users trigger fails closed.
  SELECT string_agg(t.tgname, ', ' ORDER BY t.tgname)
    INTO v_existing_triggers
  FROM pg_trigger t
  WHERE t.tgrelid = 'auth.users'::regclass
    AND NOT t.tgisinternal;

  IF v_existing_triggers IS DISTINCT FROM 'on_auth_user_created_profile' THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; expected only audited trigger on_auth_user_created_profile, found: %', COALESCE(v_existing_triggers, '<none>');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'auth.users'::regclass
      AND t.tgname = 'on_auth_user_created_profile'
      AND NOT t.tgisinternal
      AND t.tgenabled = 'O'
      AND t.tgtype = 5
      AND t.tgfoid = 'public.handle_auth_user_profile()'::regprocedure
  ) THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; audited profile trigger definition mismatch';
  END IF;

  IF to_regprocedure('public.handle_new_customer_role()') IS NOT NULL THEN
    RAISE EXCEPTION 'customer auth trigger preflight failed; function public.handle_new_customer_role() already exists';
  END IF;
END;
$preflight_customer_auth$;

-- -----------------------------------------------------------------------------
-- 1. Customer-role provisioning function.
-- -----------------------------------------------------------------------------
CREATE FUNCTION public.handle_new_customer_role()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_trusted_role text;
BEGIN
  -- Anonymous users never receive customer role. raw_user_meta_data is not
  -- trusted for identity or authorization decisions.
  IF NEW.is_anonymous IS TRUE
     OR COALESCE(NEW.raw_app_meta_data ->> 'provider', '') = 'anonymous' THEN
    RETURN NEW;
  END IF;

  -- Trusted server provisioning may assign caregiver/admin elsewhere. Do not
  -- add customer role to those accounts. Public signups have no marker and
  -- receive customer role. Marker is namespaced and never read from user data.
  v_trusted_role := NULLIF(
    btrim(COALESCE(NEW.raw_app_meta_data ->> 'temanlansia_provisioned_role', '')),
    ''
  );

  IF v_trusted_role IS NOT NULL
     AND v_trusted_role NOT IN ('customer', 'caregiver', 'admin') THEN
    RAISE EXCEPTION 'invalid trusted provisioning role';
  END IF;

  IF v_trusted_role IN ('caregiver', 'admin') THEN
    RETURN NEW;
  END IF;

  -- Existing profile trigger runs independently. FK is satisfied after both
  -- AFTER INSERT triggers complete; ON CONFLICT makes role provisioning safe
  -- for rerun/retry and never changes existing roles.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, 'customer'::public.app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.handle_new_customer_role() FROM PUBLIC;

-- Browser role checks need table privilege; RLS still limits visible rows.
GRANT SELECT ON TABLE public.user_roles TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Separate role trigger. Existing profile trigger remains untouched.
-- -----------------------------------------------------------------------------
-- Name sorts after on_auth_user_created_profile so profile FK exists first.
CREATE TRIGGER on_auth_user_created_z_customer_role
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_customer_role();

COMMIT;
