-- ============================================================================
-- MIGRATION: 202611_admin_caregiver_provisioning.sql
-- PURPOSE:
--   1. Allow adding new caregivers beyond seed 1-100 by relaxing legacy_caregiver_id.
--   2. Provide atomic admin RPC to create new caregiver + Supabase Auth account.
--   3. Provide admin RPC to manage existing caregiver Auth account / reset password.
-- SECURITY:
--   - Restricted to verified admin via public.is_role('admin').
--   - Password encrypted via pgcrypto (extensions.crypt) at database level.
--   - No frontend service_role exposure; browser admin session is never replaced.
-- STATUS:
--   REVIEW ARTIFACT ONLY. Do NOT execute without explicit user approval.
-- ============================================================================

BEGIN;

-- 1. Relaksasi constraint legacy_caregiver_id agar entri baru diizinkan (NULL atau > 100)
ALTER TABLE public.caregivers
  DROP CONSTRAINT IF EXISTS caregivers_legacy_caregiver_id_check;

ALTER TABLE public.caregivers
  ALTER COLUMN legacy_caregiver_id DROP NOT NULL;

-- 2. Kebijakan UPDATE caregiver untuk role admin (edit profil operasional)
DROP POLICY IF EXISTS caregivers_admin_update ON public.caregivers;
CREATE POLICY caregivers_admin_update ON public.caregivers
  FOR UPDATE
  USING (public.is_role('admin'))
  WITH CHECK (public.is_role('admin'));

GRANT UPDATE (name, role, category, city, area, price_per_shift, is_active, updated_at)
  ON TABLE public.caregivers
  TO authenticated;

-- 3. Fungsi RPC Admin untuk membuat akun Auth + Profil Caregiver baru
CREATE OR REPLACE FUNCTION public.admin_create_caregiver_account(
  p_email text,
  p_password text,
  p_name text,
  p_role text,
  p_category text,
  p_city text,
  p_area text,
  p_price numeric,
  p_is_active boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_new_uid uuid := gen_random_uuid();
  v_encrypted_pw text;
  v_caregiver_id uuid;
BEGIN
  -- Validasi otorisasi admin
  IF NOT public.is_role('admin') THEN
    RAISE EXCEPTION 'Akses ditolak: Hanya administrator yang dapat mendaftarkan akun caregiver.' USING ERRCODE = '42501';
  END IF;

  -- Validasi input
  IF p_email IS NULL OR p_email NOT LIKE '%@%.%' THEN
    RAISE EXCEPTION 'Format email tidak valid.' USING ERRCODE = 'P0003';
  END IF;
  IF length(p_password) < 6 THEN
    RAISE EXCEPTION 'Password minimal 6 karakter.' USING ERRCODE = 'P0003';
  END IF;

  -- Cek duplikasi email di auth.users
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = lower(p_email)) THEN
    RAISE EXCEPTION 'Email % sudah terdaftar di sistem.', p_email USING ERRCODE = '23505';
  END IF;

  v_encrypted_pw := extensions.crypt(p_password, extensions.gen_salt('bf'));

  -- Buat record Auth User (bypass customer trigger via marker)
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) VALUES (
    v_new_uid,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    lower(p_email),
    v_encrypted_pw,
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'temanlansia_provisioned_role', 'caregiver'),
    jsonb_build_object('full_name', p_name, 'role', 'caregiver'),
    now(),
    now()
  );

  -- Buat profile di public.profiles
  INSERT INTO public.profiles (id, full_name, created_at, updated_at)
  VALUES (v_new_uid, p_name, now(), now())
  ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name;

  -- Buat role caregiver di public.user_roles
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_new_uid, 'caregiver'::public.app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- Buat record caregiver di public.caregivers
  INSERT INTO public.caregivers (
    user_id, name, role, category, city, area, price_per_shift, languages, is_active
  ) VALUES (
    v_new_uid, p_name, p_role, p_category, p_city, p_area, p_price, jsonb_build_array('Indonesia'), p_is_active
  ) RETURNING id INTO v_caregiver_id;

  RETURN jsonb_build_object(
    'success', true,
    'caregiver_id', v_caregiver_id,
    'user_id', v_new_uid,
    'email', lower(p_email)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_caregiver_account FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_caregiver_account TO authenticated;

-- 4. Fungsi RPC Admin untuk mengelola akun / reset password caregiver
CREATE OR REPLACE FUNCTION public.admin_manage_caregiver_auth(
  p_caregiver_id uuid,
  p_email text DEFAULT NULL,
  p_new_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions
AS $$
DECLARE
  v_user_id uuid;
  v_encrypted_pw text;
BEGIN
  IF NOT public.is_role('admin') THEN
    RAISE EXCEPTION 'Akses ditolak: Hanya administrator yang berwenang.' USING ERRCODE = '42501';
  END IF;

  SELECT user_id INTO v_user_id FROM public.caregivers WHERE id = p_caregiver_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caregiver tidak ditemukan.' USING ERRCODE = 'P0002';
  END IF;

  -- Kasus A: Caregiver lama belum memiliki akun login (user_id IS NULL)
  IF v_user_id IS NULL THEN
    IF p_email IS NULL OR p_new_password IS NULL THEN
      RAISE EXCEPTION 'Email dan password awal wajib diisi untuk aktivasi akun baru.' USING ERRCODE = 'P0003';
    END IF;

    v_user_id := gen_random_uuid();
    v_encrypted_pw := extensions.crypt(p_new_password, extensions.gen_salt('bf'));

    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) VALUES (
      v_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      lower(p_email), v_encrypted_pw, now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'temanlansia_provisioned_role', 'caregiver'),
      jsonb_build_object('role', 'caregiver'), now(), now()
    );

    INSERT INTO public.profiles (id, full_name)
    SELECT v_user_id, name FROM public.caregivers WHERE id = p_caregiver_id
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_user_id, 'caregiver'::public.app_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    UPDATE public.caregivers SET user_id = v_user_id, updated_at = now() WHERE id = p_caregiver_id;

    RETURN jsonb_build_object('success', true, 'action', 'account_created', 'user_id', v_user_id);
  ELSE
    -- Kasus B: Caregiver sudah memiliki akun -> perbarui password dan/atau email
    IF p_new_password IS NOT NULL AND length(p_new_password) >= 6 THEN
      v_encrypted_pw := extensions.crypt(p_new_password, extensions.gen_salt('bf'));
      UPDATE auth.users SET encrypted_password = v_encrypted_pw, updated_at = now() WHERE id = v_user_id;
    END IF;

    IF p_email IS NOT NULL AND p_email LIKE '%@%.%' THEN
      UPDATE auth.users SET email = lower(p_email), updated_at = now() WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'action', 'account_updated', 'user_id', v_user_id);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_manage_caregiver_auth FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_manage_caregiver_auth TO authenticated;

COMMIT;
