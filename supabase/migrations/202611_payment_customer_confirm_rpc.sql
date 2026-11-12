-- Review-only draft. Do not run in production without explicit approval.
-- Customer demo payment: server-authoritative unpaid -> paid_demo.
-- No backfill. No booking-status repair. No frontend amount input.
BEGIN;

DO $$
DECLARE
  v_payments oid := to_regclass('public.payments');
  v_bookings oid := to_regclass('public.bookings');
  v_customers oid := to_regclass('public.customers');
  v_rpc oid := to_regprocedure('public.confirm_my_demo_payment(uuid, public.payment_method)');
  v_required record;
BEGIN
  IF v_payments IS NULL OR v_bookings IS NULL OR v_customers IS NULL THEN
    RAISE EXCEPTION 'preflight failed: required payment, booking, or customer table is missing';
  END IF;

  IF v_rpc IS NOT NULL THEN
    RAISE EXCEPTION 'preflight failed: public.confirm_my_demo_payment(uuid, public.payment_method) already exists';
  END IF;

  FOR v_required IN
    SELECT * FROM (VALUES
      ('public.customers', 'id', 'uuid'::regtype, true),
      ('public.bookings', 'id', 'uuid'::regtype, true),
      ('public.bookings', 'customer_id', 'uuid'::regtype, true),
      ('public.bookings', 'status', 'public.booking_status'::regtype, true),
      ('public.bookings', 'total_amount', 'numeric'::regtype, true),
      ('public.payments', 'id', 'uuid'::regtype, true),
      ('public.payments', 'booking_id', 'uuid'::regtype, true),
      ('public.payments', 'provider', 'text'::regtype, true),
      ('public.payments', 'method', 'public.payment_method'::regtype, true),
      ('public.payments', 'amount', 'numeric'::regtype, true),
      ('public.payments', 'status', 'public.payment_status'::regtype, true),
      ('public.payments', 'paid_at', 'timestamp with time zone'::regtype, false),
      ('public.payments', 'updated_at', 'timestamp with time zone'::regtype, true)
    ) AS x(table_name, column_name, expected_type, expected_not_null)
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_attribute AS a
      WHERE a.attrelid = to_regclass(v_required.table_name)
        AND a.attname = v_required.column_name
        AND a.attnum > 0
        AND NOT a.attisdropped
        AND a.atttypid = v_required.expected_type::oid
        AND a.attnotnull = v_required.expected_not_null
    ) THEN
      RAISE EXCEPTION 'preflight failed: %.% type or nullability mismatch', v_required.table_name, v_required.column_name;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_enum AS e
    JOIN pg_catalog.pg_type AS t ON t.oid = e.enumtypid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'payment_status' AND e.enumlabel = 'unpaid'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_enum AS e
    JOIN pg_catalog.pg_type AS t ON t.oid = e.enumtypid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'payment_status' AND e.enumlabel = 'paid_demo'
  ) THEN
    RAISE EXCEPTION 'preflight failed: required payment status labels are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_enum AS e
    JOIN pg_catalog.pg_type AS t ON t.oid = e.enumtypid
    JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'payment_method' AND e.enumlabel IN ('qris_demo', 'transfer_demo')
    GROUP BY t.oid
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'preflight failed: required demo payment methods are missing';
  END IF;
END;
$$;

CREATE FUNCTION public.confirm_my_demo_payment(
  p_booking_id uuid,
  p_method public.payment_method
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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_method NOT IN ('qris_demo'::public.payment_method, 'transfer_demo'::public.payment_method) THEN
    RAISE EXCEPTION 'unsupported demo payment method' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.customers AS c WHERE c.id = v_uid
  ) THEN
    RAISE EXCEPTION 'customer authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT b.* INTO v_booking
  FROM public.bookings AS b
  WHERE b.id = p_booking_id
    AND b.customer_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'booking not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT p.* INTO v_payment
  FROM public.payments AS p
  WHERE p.booking_id = v_booking.id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment record not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_payment.provider IS DISTINCT FROM 'demo'::text
     OR v_payment.method IS DISTINCT FROM p_method
     OR v_payment.amount IS DISTINCT FROM v_booking.total_amount THEN
    RAISE EXCEPTION 'payment record mismatch' USING ERRCODE = 'P0001';
  END IF;

  IF v_payment.status = 'paid_demo'::public.payment_status THEN
    RETURN pg_catalog.jsonb_build_object(
      'booking_id', v_booking.id,
      'payment_id', v_payment.id,
      'payment_status', v_payment.status,
      'amount', v_payment.amount,
      'paid_at', v_payment.paid_at,
      'demo', true
    );
  END IF;

  IF v_payment.status IS DISTINCT FROM 'unpaid'::public.payment_status THEN
    RAISE EXCEPTION 'payment is not unpaid' USING ERRCODE = 'P0001';
  END IF;

  -- Only unpaid payments may be confirmed, and only while booking is pending.
  -- Completed + unpaid is reconciliation work, never automatic settlement.
  IF v_booking.status IS DISTINCT FROM 'pending'::public.booking_status THEN
    RAISE EXCEPTION 'booking is not pending; manual reconciliation required' USING ERRCODE = 'P0001';
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

  RETURN pg_catalog.jsonb_build_object(
    'booking_id', v_booking.id,
    'payment_id', v_payment.id,
    'payment_status', v_payment.status,
    'amount', v_payment.amount,
    'paid_at', v_payment.paid_at,
    'demo', true
  );
END;
$$;

REVOKE ALL
ON FUNCTION public.confirm_my_demo_payment(uuid, public.payment_method)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE
ON FUNCTION public.confirm_my_demo_payment(uuid, public.payment_method)
TO authenticated;

COMMIT;
