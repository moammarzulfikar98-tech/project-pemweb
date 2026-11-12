-- Caregiver booking confirmation. Run manually after review.
-- Does not alter payment status or grant table UPDATE access.
BEGIN;

CREATE OR REPLACE FUNCTION public.confirm_my_assigned_booking(p_booking_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_payment_status public.payment_status;
  v_caregiver_user uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT b.*
    INTO v_booking
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found or not assigned' USING ERRCODE = 'P0002';
  END IF;

  SELECT c.user_id
    INTO v_caregiver_user
  FROM public.caregivers AS c
  WHERE c.id = v_booking.caregiver_id
    AND c.is_active = true;

  IF v_caregiver_user IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'booking not found or not assigned' USING ERRCODE = 'P0002';
  END IF;

  IF v_booking.status IS DISTINCT FROM 'pending'::public.booking_status THEN
    RAISE EXCEPTION 'booking is not awaiting caregiver confirmation' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.status
    INTO v_payment_status
  FROM public.payments AS p
  WHERE p.booking_id = v_booking.id
  FOR SHARE;

  IF v_payment_status IS DISTINCT FROM 'paid_demo'::public.payment_status THEN
    RAISE EXCEPTION 'payment is not verified as paid' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.bookings AS b
  SET status = 'confirmed'::public.booking_status,
      updated_at = pg_catalog.now()
  WHERE b.id = v_booking.id
    AND b.status = 'pending'::public.booking_status
  RETURNING b.* INTO v_booking;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking changed before confirmation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.booking_events (
    booking_id, from_status, to_status, actor_id
  ) VALUES (
    v_booking.id,
    'pending'::public.booking_status,
    'confirmed'::public.booking_status,
    v_uid
  );

  RETURN jsonb_build_object(
    'booking_id', v_booking.id,
    'status', v_booking.status,
    'payment_status', v_payment_status,
    'updated_at', v_booking.updated_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_my_assigned_booking(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_my_assigned_booking(uuid) TO authenticated;

COMMIT;
