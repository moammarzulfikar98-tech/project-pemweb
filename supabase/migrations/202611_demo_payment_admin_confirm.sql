-- Admin-only demo payment confirmation. Run manually after review.
-- Never represents real QRIS settlement. No backfill.
BEGIN;

DO $$
DECLARE
  v_payments oid := to_regclass('public.payments');
  v_bookings oid := to_regclass('public.bookings');
  v_transition oid := to_regprocedure('public.transition_payment(uuid,public.payment_status)');
  v_confirm oid := to_regprocedure('public.confirm_demo_payment_as_admin(uuid,numeric)');
  v_required record;
BEGIN
  IF v_transition IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.transition_payment(uuid, public.payment_status) is missing';
  END IF;

  IF v_payments IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.payments is missing';
  END IF;
  IF v_bookings IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.bookings is missing';
  END IF;
  IF v_confirm IS NOT NULL THEN
    RAISE EXCEPTION 'preflight failed: confirm_demo_payment_as_admin already exists';
  END IF;

  FOR v_required IN
    SELECT * FROM (VALUES
      ('status', 'public.payment_status'::regtype, true),
      ('paid_at', 'timestamp with time zone'::regtype, false),
      ('updated_at', 'timestamp with time zone'::regtype, true)
    ) AS x(column_name, expected_type, expected_not_null)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_attribute AS a
      WHERE a.attrelid = v_payments
        AND a.attname = v_required.column_name
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.atttypid = v_required.expected_type::oid
        AND a.attnotnull = v_required.expected_not_null
    ) THEN
      RAISE EXCEPTION 'preflight failed: public.payments.%, type or NOT NULL mismatch', v_required.column_name;
    END IF;
  END LOOP;

  FOR v_required IN
    SELECT * FROM (VALUES
      ('id', 'uuid'::regtype, true),
      ('status', 'public.booking_status'::regtype, true),
      ('total_amount', 'numeric'::regtype, true)
    ) AS x(column_name, expected_type, expected_not_null)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_attribute AS a
      WHERE a.attrelid = v_bookings
        AND a.attname = v_required.column_name
        AND a.attnum > 0 AND NOT a.attisdropped
        AND a.atttypid = v_required.expected_type::oid
        AND a.attnotnull = v_required.expected_not_null
    ) THEN
      RAISE EXCEPTION 'preflight failed: public.bookings.%, type or NOT NULL mismatch', v_required.column_name;
    END IF;
  END LOOP;

  FOR v_required IN
    SELECT * FROM (VALUES
      ('provider', 'text'::regtype, true),
      ('method', 'public.payment_method'::regtype, true),
      ('amount', 'numeric'::regtype, true)
    ) AS x(column_name, expected_type, expected_not_null)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_attribute AS a
      WHERE a.attrelid = v_payments
        AND a.attname = v_required.column_name
        AND a.attnum > 0 AND NOT a.attisdropped
        AND a.atttypid = v_required.expected_type::oid
        AND a.attnotnull = v_required.expected_not_null
    ) THEN
      RAISE EXCEPTION 'preflight failed: public.payments.%, type or NOT NULL mismatch', v_required.column_name;
    END IF;
  END LOOP;

  IF NOT (
    EXISTS (
      SELECT 1
      FROM pg_enum AS e
      JOIN pg_type AS t ON t.oid = e.enumtypid
      JOIN pg_namespace AS n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public'
        AND t.typname = 'payment_status'
        AND e.enumlabel = 'unpaid'
    )
    AND EXISTS (
      SELECT 1
      FROM pg_enum AS e
      JOIN pg_type AS t ON t.oid = e.enumtypid
      JOIN pg_namespace AS n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public'
        AND t.typname = 'payment_status'
        AND e.enumlabel = 'paid_demo'
    )
  ) THEN
    RAISE EXCEPTION 'preflight failed: required payment_status labels are missing';
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.transition_payment(uuid, public.payment_status)
FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM aclexplode(
      COALESCE(
        (SELECT p.proacl FROM pg_proc AS p WHERE p.oid = to_regprocedure('public.transition_payment(uuid,public.payment_status)')),
        acldefault('f', (SELECT p.proowner FROM pg_proc AS p WHERE p.oid = to_regprocedure('public.transition_payment(uuid,public.payment_status)')))
      )
    ) AS ax
    WHERE ax.grantee = 0
      AND ax.privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'post-revoke failed: PUBLIC retains EXECUTE';
  END IF;

  IF has_function_privilege('anon', 'public.transition_payment(uuid,public.payment_status)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.transition_payment(uuid,public.payment_status)', 'EXECUTE') THEN
    RAISE EXCEPTION 'post-revoke failed: transition_payment remains executable by anon/authenticated';
  END IF;
END;
$$;

CREATE FUNCTION public.confirm_demo_payment_as_admin(
  p_booking_id uuid,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_booking public.bookings;
  v_payment public.payments;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = v_uid
      AND role = 'admin'::public.app_role
  ) INTO v_is_admin;

  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'admin authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT b.* INTO v_booking
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_booking.status IS DISTINCT FROM 'pending'::public.booking_status THEN
    RAISE EXCEPTION 'booking is not pending' USING ERRCODE = 'P0001';
  END IF;

  IF p_amount IS NULL OR p_amount < 0 OR p_amount IS DISTINCT FROM v_booking.total_amount THEN
    RAISE EXCEPTION 'payment amount mismatch' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.* INTO v_payment
  FROM public.payments AS p
  WHERE p.booking_id = v_booking.id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment record not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_payment.provider IS DISTINCT FROM 'demo'::text
     OR v_payment.method IS DISTINCT FROM 'qris_demo'::public.payment_method
     OR v_payment.amount IS DISTINCT FROM v_booking.total_amount
     OR v_payment.amount IS DISTINCT FROM p_amount THEN
    RAISE EXCEPTION 'payment record mismatch' USING ERRCODE = 'P0001';
  END IF;

  IF v_payment.status IS DISTINCT FROM 'unpaid'::public.payment_status THEN
    RAISE EXCEPTION 'payment is not unpaid' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.payments AS p
  SET status = 'paid_demo'::public.payment_status,
      paid_at = pg_catalog.now(),
      updated_at = pg_catalog.now()
  WHERE p.id = v_payment.id
    AND p.status = 'unpaid'::public.payment_status
  RETURNING p.* INTO v_payment;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment changed before confirmation' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'booking_id', v_booking.id,
    'payment_id', v_payment.id,
    'payment_status', v_payment.status,
    'amount', v_payment.amount,
    'paid_at', v_payment.paid_at,
    'demo', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_demo_payment_as_admin(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_demo_payment_as_admin(uuid, numeric) TO authenticated;

COMMIT;
