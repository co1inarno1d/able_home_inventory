-- QuickBooks OAuth token storage
-- One row per connected QB company (realm). In practice just one row.

create table if not exists qb_tokens (
  realm_id      text primary key,
  access_token  text not null,
  refresh_token text not null,
  expires_at    timestamptz not null,
  updated_at    timestamptz not null default now()
);

-- Only admins/service role should touch this table.
-- The edge function uses the service role key so it bypasses RLS entirely.
-- We still enable RLS so no anon/authenticated client can read tokens directly.
alter table qb_tokens enable row level security;

-- No client-side access at all — edge function owns this table via service role.
