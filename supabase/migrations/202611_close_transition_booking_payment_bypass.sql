-- Close legacy transition_booking payment bypass.
-- Run manually after review. No payment mutation.
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
  payment_state public.payment_status;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
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

  SELECT * INTO b
  FROM public.bookings
  WHERE id = p_booking
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found';
  END IF;

  old_status := b.status;

  SELECT c.user_id INTO caregiver_user
  FROM public.caregivers AS c
  WHERE c.id = b.caregiver_id
    AND c.is_active = true;

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
      p_to IN (
        'confirmed'::public.booking_status,
        'in_progress'::public.booking_status,
        'completed'::public.booking_status
      )
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
    RAISE EXCEPTION 'booking transition forbidden' USING ERRCODE = '42501';
  END IF;

  IF (b.status, p_to) = (
    'pending'::public.booking_status,
    'confirmed'::public.booking_status
  ) THEN
    SELECT p.status INTO payment_state
    FROM public.payments AS p
    WHERE p.booking_id = b.id
    FOR SHARE;

    IF payment_state IS DISTINCT FROM 'paid_demo'::public.payment_status THEN
      RAISE EXCEPTION 'payment is not verified as paid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  UPDATE public.bookings
  SET status = p_to,
      updated_at = pg_catalog.now()
  WHERE id = p_booking
  RETURNING * INTO b;

  INSERT INTO public.booking_events (
    booking_id, from_status, to_status, actor_id
  ) VALUES (
    b.id, old_status, p_to, uid
  );

  RETURN b;
END;
$$;

REVOKE ALL ON FUNCTION public.transition_booking(uuid, public.booking_status) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transition_booking(uuid, public.booking_status) TO authenticated;

COMMIT;
