-- Post-execution verification only. Do not run before explicit migration approval.
-- Source canonical SHA-256: 3907c0e32e63321f21d5bcf24a4ad05eb22c9b3dee0593897d468240f599e6b5
SELECT count(*) AS caregiver_count, min(legacy_caregiver_id) AS min_id, max(legacy_caregiver_id) AS max_id, count(DISTINCT legacy_caregiver_id) AS unique_id_count FROM public.caregivers;
SELECT legacy_caregiver_id, count(*) AS duplicate_count FROM public.caregivers GROUP BY legacy_caregiver_id HAVING count(*) <> 1 ORDER BY legacy_caregiver_id;
WITH expected AS (SELECT generate_series(1,100) AS id) SELECT expected.id AS missing_id FROM expected LEFT JOIN public.caregivers c ON c.legacy_caregiver_id=expected.id WHERE c.legacy_caregiver_id IS NULL ORDER BY expected.id;
SELECT legacy_caregiver_id AS extra_id FROM public.caregivers WHERE legacy_caregiver_id NOT BETWEEN 1 AND 100 ORDER BY legacy_caregiver_id;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('btree_gist','pgcrypto') ORDER BY extname;
SELECT conname, contype FROM pg_constraint WHERE conname IN ('caregiver_availability_no_overlap','bookings_no_overlap') ORDER BY conname;
SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename IN ('profiles','user_roles','customers','customer_addresses','elder_profiles','elder_addresses','caregivers','caregiver_availability','bookings','live_reports','payments','reviews','sos_events','booking_events','notifications') ORDER BY tablename;
WITH expected(policyname, tablename) AS (VALUES
 ('caregivers_public_read','caregivers'),('profiles_self','profiles'),('roles_self','user_roles'),('customer_self','customers'),('elder_owner','elder_profiles'),
 ('booking_read_owner_or_assignee','bookings'),('booking_insert_customer','bookings'),('booking_update_admin','bookings'),
 ('report_read_owner_or_assignee','live_reports'),('report_insert_assigned','live_reports'),('report_update_assigned','live_reports'),
 ('review_insert_completed_owner','reviews'),('review_read_owner','reviews'),('notification_self','notifications'),
 ('customer_addresses_read','customer_addresses'),('customer_addresses_insert','customer_addresses'),('customer_addresses_update','customer_addresses'),('customer_addresses_delete','customer_addresses'),
 ('elder_addresses_read','elder_addresses'),('elder_addresses_insert','elder_addresses'),('elder_addresses_update','elder_addresses'),('elder_addresses_delete','elder_addresses'),
 ('availability_public_read','caregiver_availability'),('availability_owner_write','caregiver_availability'),('availability_owner_update','caregiver_availability'),('availability_owner_delete','caregiver_availability'),
 ('payment_owner_read','payments'),('payment_owner_insert','payments'),('sos_owner_read','sos_events'),('sos_owner_insert','sos_events'),('booking_events_owner_read','booking_events'))
SELECT e.policyname,e.tablename FROM expected e LEFT JOIN pg_policies p ON p.schemaname='public' AND p.tablename=e.tablename AND p.policyname=e.policyname WHERE p.policyname IS NULL;
-- storage.objects policy coverage; empty result means all expected policies exist.
WITH expected(policyname, cmd) AS (VALUES ('storage_caregiver_read','SELECT'),('storage_caregiver_insert','INSERT'),('storage_caregiver_update','UPDATE'),('storage_caregiver_delete','DELETE'),('storage_customer_read','SELECT'),('storage_customer_insert','INSERT'),('storage_customer_update','UPDATE'),('storage_customer_delete','DELETE'),('storage_elder_read','SELECT'),('storage_elder_insert','INSERT'),('storage_elder_update','UPDATE'),('storage_elder_delete','DELETE')) SELECT e.policyname,e.cmd FROM expected e LEFT JOIN pg_policies p ON p.schemaname='storage' AND p.tablename='objects' AND p.policyname=e.policyname WHERE p.policyname IS NULL;
SELECT id, name, public FROM storage.buckets WHERE id IN ('caregiver-media','customer-media','elder-media') ORDER BY id;
-- Storage policy allowlist; any extra policy requires manual review before approval.
WITH expected(policyname) AS (VALUES ('storage_caregiver_read'),('storage_caregiver_insert'),('storage_caregiver_update'),('storage_caregiver_delete'),('storage_customer_read'),('storage_customer_insert'),('storage_customer_update'),('storage_customer_delete'),('storage_elder_read'),('storage_elder_insert'),('storage_elder_update'),('storage_elder_delete')) SELECT p.policyname FROM pg_policies p LEFT JOIN expected e ON e.policyname=p.policyname WHERE p.schemaname='storage' AND p.tablename='objects' AND e.policyname IS NULL ORDER BY p.policyname;
SELECT count(*) AS expected_policy_count, count(DISTINCT policyname) AS unique_policy_count FROM pg_policies WHERE (schemaname='public' AND policyname IN ('caregivers_public_read','profiles_self','roles_self','customer_self','elder_owner','booking_read_owner_or_assignee','booking_insert_customer','booking_update_admin','report_read_owner_or_assignee','report_insert_assigned','report_update_assigned','review_insert_completed_owner','review_read_owner','notification_self','customer_addresses_read','customer_addresses_insert','customer_addresses_update','customer_addresses_delete','elder_addresses_read','elder_addresses_insert','elder_addresses_update','elder_addresses_delete','availability_public_read','availability_owner_write','availability_owner_update','availability_owner_delete','payment_owner_read','payment_owner_insert','sos_owner_read','sos_owner_insert','booking_events_owner_read')) OR (schemaname='storage' AND policyname LIKE 'storage_%');
-- Canonical JSON matches tools/verify_checksum.py: compact UTF-8 JSON, sorted object keys, array order preserved.
CREATE OR REPLACE FUNCTION pg_temp.canonical_jsonb(j jsonb) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE k text; v jsonb; out text;
BEGIN
  CASE jsonb_typeof(j)
    WHEN 'object' THEN
      SELECT COALESCE(string_agg(to_json(k)::text || ':' || pg_temp.canonical_jsonb(v), ',' ORDER BY k), '') INTO out
      FROM jsonb_each(j);
      RETURN '{' || out || '}';
    WHEN 'array' THEN
      SELECT COALESCE(string_agg(pg_temp.canonical_jsonb(value), ',' ORDER BY ord), '') INTO out
      FROM jsonb_array_elements(j) WITH ORDINALITY AS a(value, ord);
      RETURN '[' || out || ']';
    WHEN 'string' THEN RETURN to_json(j #>> '{}')::text;
    ELSE RETURN j::text;
  END CASE;
END $$;
DO $$
DECLARE db_hash text; target_hash text := '3907c0e32e63321f21d5bcf24a4ad05eb22c9b3dee0593897d468240f599e6b5'; payload text; digest_schema text;
BEGIN
  SELECT pg_namespace.nspname INTO digest_schema
  FROM pg_proc JOIN pg_namespace ON pg_namespace.oid=pg_proc.pronamespace
  WHERE pg_proc.proname='digest' AND pg_proc.proargtypes='17 25'::oidvector
  ORDER BY (pg_namespace.nspname='public') DESC LIMIT 1;
  IF digest_schema IS NULL THEN RAISE EXCEPTION 'pgcrypto digest(bytea,text) unavailable'; END IF;
  SELECT pg_temp.canonical_jsonb(jsonb_agg(source_payload ORDER BY legacy_caregiver_id)) INTO payload FROM public.caregivers;
  EXECUTE format('SELECT encode(%I.digest(convert_to($1, ''UTF8''), ''sha256''), ''hex'')', digest_schema) INTO db_hash USING payload;
  RAISE NOTICE 'canonical_db_hash=%', db_hash;
  IF db_hash <> target_hash THEN RAISE EXCEPTION 'checksum mismatch: expected %, got %', target_hash, db_hash; END IF;
END $$;
