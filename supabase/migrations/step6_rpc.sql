-- TemanLansia Langkah 6: RPC status transitions only.
-- Approved scope: functions/grants only. No tables, columns, enums, RLS, or data changes.
-- Execute only in Supabase SQL Editor after review. This artifact has not been executed here.

BEGIN;

CREATE OR REPLACE FUNCTION public.transition_booking(
  p_booking uuid,
  p_to public.booking_status
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  b public.bookings;
  old_status public.booking_status;
  uid uuid := auth.uid();
  caregiver_user uuid;
  is_admin boolean;
  is_customer boolean;
  is_caregiver boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = uid AND role = 'admin'::public.app_role
  ) INTO is_admin;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = uid AND role = 'customer'::public.app_role
  ) INTO is_customer;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = uid AND role = 'caregiver'::public.app_role
  ) INTO is_caregiver;

  SELECT *
    INTO b
  FROM public.bookings
  WHERE id = p_booking
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found';
  END IF;

  old_status := b.status;

  SELECT c.user_id
    INTO caregiver_user
  FROM public.caregivers c
  WHERE c.id = b.caregiver_id;

  IF NOT (
    (b.status, p_to) IN (
      ('pending'::public.booking_status, 'confirmed'::public.booking_status),
      ('pending'::public.booking_status, 'cancelled'::public.booking_status),
      ('confirmed'::public.booking_status, 'in_progress'::public.booking_status),
      ('confirmed'::public.booking_status, 'cancelled'::public.booking_status),
      ('in_progress'::public.booking_status, 'completed'::public.booking_status)
    )
  ) THEN
    RAISE EXCEPTION 'invalid booking transition';
  END IF;

  IF NOT (
    is_admin
    OR (
      p_to IN ('confirmed'::public.booking_status, 'in_progress'::public.booking_status,
               'completed'::public.booking_status)
      AND is_caregiver
      AND caregiver_user = uid
    )
    OR (
      p_to = 'cancelled'::public.booking_status
      AND (
        (is_customer AND b.customer_id = uid)
        OR (is_caregiver AND caregiver_user = uid)
      )
    )
  ) THEN
    RAISE EXCEPTION 'booking transition forbidden';
  END IF;

  UPDATE public.bookings
  SET status = p_to, updated_at = pg_catalog.now()
  WHERE id = p_booking
  RETURNING * INTO b;

  INSERT INTO public.booking_events (
    booking_id, from_status, to_status, actor_id
  )
  VALUES (
    b.id,
    old_status,
    p_to,
    uid
  );

  RETURN b;
END;
$$;

CREATE OR REPLACE FUNCTION public.transition_payment(
  p_payment uuid,
  p_to public.payment_status
)
RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  p public.payments;
  b public.bookings;
  uid uuid := auth.uid();
  is_admin boolean;
  is_customer boolean;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = uid AND role = 'admin'::public.app_role
  ) INTO is_admin;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = uid AND role = 'customer'::public.app_role
  ) INTO is_customer;

  SELECT p.*
    INTO p
  FROM public.payments p
  WHERE p.id = p_payment
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment not found';
  END IF;

  SELECT b.*
    INTO b
  FROM public.bookings b
  WHERE b.id = p.booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment booking not found';
  END IF;

  IF NOT (
    (p.status, p_to) IN (
      ('unpaid'::public.payment_status, 'pending'::public.payment_status),
      ('pending'::public.payment_status, 'paid_demo'::public.payment_status),
      ('pending'::public.payment_status, 'failed_demo'::public.payment_status),
      ('paid_demo'::public.payment_status, 'refunded_demo'::public.payment_status)
    )
  ) THEN
    RAISE EXCEPTION 'invalid payment transition';
  END IF;

  IF NOT (
    is_admin
    OR (is_customer AND b.customer_id = uid)
  ) THEN
    RAISE EXCEPTION 'payment transition forbidden';
  END IF;

  UPDATE public.payments
  SET status = p_to,
      paid_at = CASE
        WHEN p_to = 'paid_demo'::public.payment_status THEN pg_catalog.now()
        WHEN p_to = 'refunded_demo'::public.payment_status THEN paid_at
        ELSE paid_at
      END,
      updated_at = pg_catalog.now()
  WHERE id = p_payment
  RETURNING * INTO p;

  RETURN p;
END;
$$;

REVOKE ALL ON FUNCTION public.transition_booking(uuid, public.booking_status) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transition_payment(uuid, public.payment_status) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transition_booking(uuid, public.booking_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transition_payment(uuid, public.payment_status) TO authenticated;

COMMIT;
