-- TemanLansia SQL Tahap 1: schema only; FRESH-SCHEMA ONLY.
-- Requires none of 15 target tables to exist in public schema.
-- Fails closed on partial/schema drift. Not a general rerun migration.
-- No RLS, Storage, function, trigger, or seed.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;

DO $$ BEGIN
  CREATE TYPE public.app_role AS ENUM ('customer','caregiver','admin');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE public.booking_status AS ENUM ('pending','confirmed','in_progress','completed','cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE public.availability_status AS ENUM ('available','blocked');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE public.payment_status AS ENUM ('unpaid','pending','paid_demo','failed_demo','refunded_demo');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$ BEGIN
  CREATE TYPE public.payment_method AS ENUM ('qris_demo','transfer_demo','cash_demo');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Stage 1 targets an empty public schema. Fail closed on partial/schema-drift state.
DO $$
DECLARE
  present text;
BEGIN
  SELECT string_agg(format('public.%I', table_name), ', ' ORDER BY table_name)
    INTO present
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name IN (
      'profiles','user_roles','customers','customer_addresses','elder_profiles',
      'elder_addresses','caregivers','caregiver_availability','bookings',
      'live_reports','payments','reviews','sos_events','booking_events','notifications'
    );
  IF present IS NOT NULL THEN
    RAISE EXCEPTION 'Stage 1 requires empty schema; existing tables: %', present;
  END IF;
END $$;

DO $$
DECLARE
  expected text[] := ARRAY['customer','caregiver','admin'];
  actual text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO actual
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'app_role';
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'app_role enum mismatch; expected %, got %', expected, actual;
  END IF;
END $$;

DO $$
DECLARE
  expected text[] := ARRAY['pending','confirmed','in_progress','completed','cancelled'];
  actual text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO actual
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'booking_status';
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'booking_status enum mismatch; expected %, got %', expected, actual;
  END IF;
END $$;

DO $$
DECLARE
  expected text[] := ARRAY['available','blocked'];
  actual text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO actual
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'availability_status';
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'availability_status enum mismatch; expected %, got %', expected, actual;
  END IF;
END $$;

DO $$
DECLARE
  expected text[] := ARRAY['unpaid','pending','paid_demo','failed_demo','refunded_demo'];
  actual text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO actual
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'payment_status';
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'payment_status enum mismatch; expected %, got %', expected, actual;
  END IF;
END $$;

DO $$
DECLARE
  expected text[] := ARRAY['qris_demo','transfer_demo','cash_demo'];
  actual text[];
BEGIN
  SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO actual
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typname = 'payment_method';
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'payment_method enum mismatch; expected %, got %', expected, actual;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL,
  phone text,
  avatar_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role)
);

CREATE TABLE IF NOT EXISTS public.customers (
  id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  emergency_contact_name text NOT NULL,
  emergency_contact_phone text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.customer_addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  label text NOT NULL,
  recipient_name text NOT NULL,
  phone text NOT NULL,
  address_line text NOT NULL,
  city text NOT NULL,
  province text NOT NULL,
  postal_code text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  is_default boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  UNIQUE (id, customer_id)
);

CREATE TABLE IF NOT EXISTS public.elder_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  name text NOT NULL,
  date_of_birth date,
  gender text,
  conditions jsonb NOT NULL,
  allergies text,
  mobility text NOT NULL CHECK (mobility IN ('mandiri','butuh_bantuan','tirah_baring')),
  medical_notes text,
  photo_path text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(conditions) = 'array' AND jsonb_array_length(conditions) > 0),
  UNIQUE (id, customer_id)
);

CREATE TABLE IF NOT EXISTS public.elder_addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  elder_profile_id uuid NOT NULL REFERENCES public.elder_profiles(id) ON DELETE CASCADE,
  address_line text NOT NULL,
  city text NOT NULL,
  province text NOT NULL,
  postal_code text,
  latitude numeric(9,6) NOT NULL,
  longitude numeric(9,6) NOT NULL,
  access_notes text,
  is_default boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (latitude BETWEEN -90 AND 90),
  CHECK (longitude BETWEEN -180 AND 180),
  UNIQUE (id, elder_profile_id)
);

CREATE TABLE IF NOT EXISTS public.caregivers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE REFERENCES public.profiles(id) ON DELETE SET NULL,
  legacy_caregiver_id integer NOT NULL UNIQUE CHECK (legacy_caregiver_id BETWEEN 1 AND 100),
  name text NOT NULL,
  role text NOT NULL,
  city text NOT NULL,
  area text NOT NULL,
  category text NOT NULL,
  gender text NOT NULL,
  age smallint CHECK (age BETWEEN 18 AND 100),
  languages jsonb NOT NULL,
  price_per_shift numeric(12,2) NOT NULL CHECK (price_per_shift >= 0),
  rating numeric(2,1) NOT NULL CHECK (rating BETWEEN 0 AND 5),
  reviews_count integer NOT NULL DEFAULT 0 CHECK (reviews_count >= 0),
  badge text,
  latitude numeric(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude numeric(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  description text,
  photo_path text,
  is_active boolean NOT NULL DEFAULT true,
  source_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(languages) = 'array')
);

CREATE TABLE IF NOT EXISTS public.caregiver_availability (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caregiver_id uuid NOT NULL REFERENCES public.caregivers(id) ON DELETE CASCADE,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  status public.availability_status NOT NULL DEFAULT 'available',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at)
);

CREATE TABLE IF NOT EXISTS public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  caregiver_id uuid NOT NULL REFERENCES public.caregivers(id),
  elder_profile_id uuid NOT NULL,
  elder_address_id uuid NOT NULL,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  status public.booking_status NOT NULL DEFAULT 'pending',
  total_amount numeric(12,2) NOT NULL CHECK (total_amount >= 0),
  address_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at),
  FOREIGN KEY (elder_profile_id, customer_id)
    REFERENCES public.elder_profiles(id, customer_id),
  FOREIGN KEY (elder_address_id, elder_profile_id)
    REFERENCES public.elder_addresses(id, elder_profile_id)
);

CREATE TABLE IF NOT EXISTS public.live_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  report_date date NOT NULL,
  content jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
  provider text NOT NULL DEFAULT 'demo' CHECK (provider = 'demo'),
  method public.payment_method NOT NULL,
  provider_reference text,
  amount numeric(12,2) NOT NULL CHECK (amount >= 0),
  currency char(3) NOT NULL DEFAULT 'IDR',
  status public.payment_status NOT NULL DEFAULT 'unpaid',
  paid_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
  rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sos_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  elder_profile_id uuid NOT NULL,
  booking_id uuid REFERENCES public.bookings(id),
  emergency_number text NOT NULL CHECK (emergency_number IN ('112','119')),
  latitude numeric(9,6),
  longitude numeric(9,6),
  triggered_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'initiated',
  metadata jsonb,
  CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
  CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  FOREIGN KEY (elder_profile_id, customer_id)
    REFERENCES public.elder_profiles(id, customer_id)
);

CREATE TABLE IF NOT EXISTS public.booking_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
  from_status public.booking_status,
  to_status public.booking_status NOT NULL,
  actor_id uuid REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  booking_id uuid REFERENCES public.bookings(id) ON DELETE CASCADE,
  type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS one_default_customer_address
  ON public.customer_addresses(customer_id) WHERE is_default;
CREATE UNIQUE INDEX IF NOT EXISTS one_default_elder_address
  ON public.elder_addresses(elder_profile_id) WHERE is_default;
ALTER TABLE public.caregiver_availability
  DROP CONSTRAINT IF EXISTS caregiver_availability_no_overlap;
ALTER TABLE public.caregiver_availability
  ADD CONSTRAINT caregiver_availability_no_overlap
  EXCLUDE USING gist (caregiver_id WITH =, tstzrange(start_at, end_at, '[)') WITH &&)
  WHERE (status = 'available');
ALTER TABLE public.bookings
  DROP CONSTRAINT IF EXISTS bookings_no_overlap;
ALTER TABLE public.bookings
  ADD CONSTRAINT bookings_no_overlap
  EXCLUDE USING gist (caregiver_id WITH =, tstzrange(start_at, end_at, '[)') WITH &&)
  WHERE (status IN ('pending','confirmed','in_progress'));

COMMIT;
