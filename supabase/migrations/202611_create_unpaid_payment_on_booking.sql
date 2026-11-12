-- Create initial unpaid payment row for every new booking.
-- Run manually after review. Does not backfill existing bookings or mark payment paid.
BEGIN;

DO $$
DECLARE
  v_payments oid := to_regclass('public.payments');
  v_bookings oid := to_regclass('public.bookings');
  v_booking_id_attnum smallint;
  v_unique_booking_id boolean;
  v_required record;
BEGIN
  IF v_payments IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.payments is missing';
  END IF;
  IF v_bookings IS NULL THEN
    RAISE EXCEPTION 'preflight failed: public.bookings is missing';
  END IF;

  FOR v_required IN
    SELECT * FROM (VALUES
      ('booking_id', 'uuid'::regtype, true),
      ('provider', 'text'::regtype, true),
      ('method', 'public.payment_method'::regtype, true),
      ('amount', 'numeric'::regtype, true),
      ('status', 'public.payment_status'::regtype, true)
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

  FOR v_required IN
    SELECT * FROM (VALUES
      ('id', 'uuid'::regtype, true),
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

  SELECT a.attnum INTO v_booking_id_attnum
  FROM pg_attribute AS a
  WHERE a.attrelid = v_payments AND a.attname = 'booking_id'
    AND a.attnum > 0 AND NOT a.attisdropped;

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint AS con
    WHERE con.conrelid = v_payments AND con.contype IN ('p', 'u')
      AND con.conkey = ARRAY[v_booking_id_attnum::smallint]
  ) INTO v_unique_booking_id;

  IF NOT v_unique_booking_id THEN
    RAISE EXCEPTION 'preflight failed: public.payments.booking_id lacks single-column PRIMARY KEY/UNIQUE constraint';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_enum AS e JOIN pg_type AS t ON t.oid = e.enumtypid
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'payment_method' AND e.enumlabel = 'qris_demo'
  ) THEN RAISE EXCEPTION 'preflight failed: public.payment_method.qris_demo is missing'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_enum AS e JOIN pg_type AS t ON t.oid = e.enumtypid
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'payment_status' AND e.enumlabel = 'unpaid'
  ) THEN RAISE EXCEPTION 'preflight failed: public.payment_status.unpaid is missing'; END IF;

  IF to_regprocedure('public.create_unpaid_payment_for_booking()') IS NOT NULL THEN
    RAISE EXCEPTION 'preflight failed: function already exists';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = to_regclass('public.bookings')
      AND tgname = 'bookings_create_unpaid_payment' AND NOT tgisinternal
  ) THEN RAISE EXCEPTION 'preflight failed: trigger already exists'; END IF;
END;
$$;

CREATE FUNCTION public.create_unpaid_payment_for_booking()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.payments (booking_id, provider, method, amount, status)
  VALUES (NEW.id, 'demo', 'qris_demo'::public.payment_method,
          NEW.total_amount, 'unpaid'::public.payment_status)
  ON CONFLICT (booking_id) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.create_unpaid_payment_for_booking() FROM PUBLIC;

CREATE TRIGGER bookings_create_unpaid_payment
AFTER INSERT ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.create_unpaid_payment_for_booking();

COMMIT;
