# Supabase migration preparation (6B)

Status: PREPARED ONLY. SQL NOT RUN. No Supabase/frontend changes.

Order: verify project and `btree_gist` -> types/schema -> FK/check/exclusion constraints -> functions/triggers -> RLS -> exact seed -> verification.

Required config: project URL, Supabase CLI auth or dashboard access, migration role, `btree_gist` availability, Storage buckets/prefix policies. Keep service-role key, DB password, JWT secret, PAN/CVC, and gateway secrets out of chat/repo.

Seed source: `data/caregivers.json`; expected exact 100 rows, IDs 1..100. `source_payload` preserves original records.

Before execution: independent RLS/security review, staging run, Storage policy review, and explicit user approval for implementation.
