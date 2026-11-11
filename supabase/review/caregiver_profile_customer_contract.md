# Caregiver Profile & Assigned Customer Contract

Status: review draft only. No SQL execution.

## 1. Caregiver profile update

### RPC

Use server-side RPC, not browser `.update()` on `public.caregivers`. RLS controls row ownership; RPC body controls column allowlist and derives caregiver ID from `auth.uid()`.

```sql
public.update_my_caregiver_profile(p_patch jsonb)
```

Ownership source:

```text
caregivers.user_id = auth.uid()
```

RPC security contract:

```sql
SECURITY DEFINER
SET search_path = pg_catalog, public
REVOKE ALL ON FUNCTION public.update_my_caregiver_profile(jsonb) FROM PUBLIC
GRANT EXECUTE ON FUNCTION public.update_my_caregiver_profile(jsonb) TO authenticated
```

Body must validate `auth.uid() IS NOT NULL`, resolve exactly one active caregiver with `caregivers.user_id = auth.uid() AND is_active = true`, and perform an explicit ownership check. It must not rely on RLS because `SECURITY DEFINER` can bypass caller row policies.

RPC must reject an empty patch and unknown keys with structured errors, for example `P0003` plus a stable error code/message payload. Client-supplied caregiver ID is not accepted as an ownership control. It must reject any `photo_path` outside the resolved caregiver's canonical `caregiver-media/<caregiver_uuid>/...` path.

RPC updates only the one caregiver row resolved from `auth.uid()` and never silently ignores a requested mutation.

Editable fields:

```json
{
  "name": "string|null",
  "role": "string|null",
  "category": "string|null",
  "gender": "string|null",
  "age": "integer|null",
  "city": "string|null",
  "area": "string|null",
  "languages": "string[]",
  "description": "string|null",
  "photo_path": "string|null"
}
```

Server-enforced non-editable fields: `id`, `user_id`, `legacy_caregiver_id`, `price_per_shift`, `rating`, `reviews_count`, coordinates, `is_active`, `source_payload`, timestamps.

Response:

```json
{
  "id": "uuid",
  "user_id": "uuid",
  "name": "string|null",
  "role": "string|null",
  "category": "string|null",
  "gender": "string|null",
  "age": "integer|null",
  "city": "string|null",
  "area": "string|null",
  "languages": ["string"],
  "description": "string|null",
  "photo_path": "string|null",
  "rating": "number",
  "reviews_count": "integer",
  "price_per_shift": "number"
}
```

`NULL` display: `Belum tersedia`.

Validation: text is trimmed and bounded by existing database limits/contracts; `age` must be `NULL` or integer 18–100; `languages` must be JSON array of non-empty strings; `photo_path` must be a caregiver Storage path or `NULL`.

No `profiles` update is needed. Caregiver display fields live in `caregivers`; `profiles` has no approved caregiver-editable field in this contract.

### Photo

Storage object path:

```text
caregiver-media/<caregiver_uuid>/<filename>
```

Storage policy must validate all three conditions: bucket is exactly `caregiver-media`; first path segment is a valid caregiver UUID; and that UUID resolves to `caregivers.id` with `caregivers.user_id = auth.uid()`. Separate INSERT, UPDATE, DELETE policies must enforce the same ownership predicate.

The profile RPC may accept only a server-validated canonical `photo_path` under that owned path; it must reject another caregiver's path.

Column allowlist is enforced inside `update_my_caregiver_profile`; database column privileges and RPC `REVOKE/GRANT` are deployment requirements, not frontend assumptions.

Policy checks both bucket and first path segment against `caregivers.id` where `caregivers.user_id = auth.uid()`.

Client resolves private object with a short-lived signed URL. `photo_path` remains canonical; URL is never stored as profile data.

## 2. Assigned customer detail

### RPC

```sql
public.get_assigned_customer_details(p_booking_id uuid)
```

Authentication: `authenticated` only. Function contract:

```sql
SECURITY DEFINER
SET search_path = pg_catalog, public
REVOKE ALL ON FUNCTION public.get_assigned_customer_details(uuid) FROM PUBLIC
GRANT EXECUTE ON FUNCTION public.get_assigned_customer_details(uuid) TO authenticated
```

Body validates `auth.uid() IS NOT NULL`, resolves exactly one active caregiver, and performs explicit ownership filtering. It must not rely on RLS because `SECURITY DEFINER` can bypass caller row policies. Missing booking and booking assigned to another caregiver return the same `P0002` contract; do not reveal ownership through error differences.

Ownership: returns row only when:

```text
bookings.id = p_booking_id
AND bookings.caregiver_id = caregivers.id
AND caregivers.user_id = auth.uid()
```

No table-wide caregiver SELECT grant is needed for customer, elder, or address tables.

Response is one row or no row:

```json
{
  "booking_id": "uuid|null",
  "assigned_caregiver_id": "uuid|null",
  "assigned_caregiver_name": "string|null",
  "customer_id": "uuid|null",
  "customer_name": "string|null",
  "customer_contact_name": "string|null",
  "customer_contact_phone": "string|null",
  "elder_profile_id": "uuid|null",
  "elder_name": "string|null",
  "elder_age": "integer|null",
  "elder_gender": "string|null",
  "health_conditions": "jsonb|null",  
  "caregiver_languages_type": "jsonb",  
  "caregiver_updated_at_type": "timestamptz" ,
  "allergies": "string|null",
  "mobility": "string|null",
  "medical_notes": "string|null",
  "address_id": "uuid|null",
  "address_line": "string|null",
  "city": "string|null",
  "province": "string|null",
  "postal_code": "string|null",
  "access_notes": "string|null",
  "address_snapshot": "object|null",
  "start_at": "ISO-8601 timestamp|null",
  "end_at": "ISO-8601 timestamp|null",
  "shift_type": "Pagi|Malam|24 Jam|null",
  "duration_hours": "number|null",
  "booking_status": "string|null",
  "total_amount": "number|null"
}
```

Date/time: API returns `timestamptz` as ISO-8601. UI formats in `Asia/Jakarta`; it must not recalculate server pricing or overwrite snapshot values.

`shift_type` and `duration_hours` are derived only when exact start/end boundaries match approved booking shift rules. Otherwise both are `NULL`.

Address source: current relational `elder_addresses` values plus immutable `bookings.address_snapshot`. Frontend shows relational fields first and snapshot fields where contract specifies; missing values display `Belum tersedia`.

Customer phone label must remain `Nomor kontak` because current schema stores `customers.emergency_contact_phone`; do not label it WhatsApp unless product schema confirms that meaning.

Errors:

- `42501`: caller not authorized / ownership denied.
- `P0002`: booking not found or not assigned to current caregiver.
- `P0003`: invalid booking ID.
- Other database errors: generic UI error; never expose stack or SQL details.

## 3. Explicit non-goals

- No migration `000002` or `000003` change.
- No booking, payment, status, Live Report, or rating mutation.
- No customer/elder/address global read policy for caregivers.
- No repair, backfill, dummy customer, or fabricated certification/experience.
- Runtime RLS, RPC, and Storage tests remain required before claiming persistence or production readiness.
