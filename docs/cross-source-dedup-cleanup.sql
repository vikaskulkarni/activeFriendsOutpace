-- Cross-source duplicate cleanup (phone_gps supersedes Health Connect / HealthKit imports)
--
-- One-time data fix for duplicates created BEFORE the reverse-direction dedup
-- shipped (see lib/features/import/data/cross_source_dedup.dart). These are
-- activities recorded by Outpace GPS that were ALSO imported from the phone's
-- own health tracker (Health Connect / HealthKit), because the import landed
-- before the GPS row existed and nothing reconciled afterwards.
--
-- Policy: the GPS record is primary (it has the map route); the overlapping
-- import is marked excluded (which zeroes its points and leaderboard totals)
-- and linked to the GPS activity via dup_group_id. GPS rows are never touched
-- except to record the group link. Matching rule mirrors the app: same user,
-- type-agnostic, time overlap > 70% of the shorter activity's duration.
--
-- SCOPE: only activities started on/after Monday 2026-11-02 00:00 IST
-- (= 2026-11-01 18:30 UTC) are considered, on BOTH sides of the pair, so older
-- data is never modified. Both the GPS and the import must fall in range. To
-- change the window, edit the two `>= timestamptz '2026-11-02 00:00:00+05:30'`
-- lines in each step (adjust the +05:30 offset if your prod is not IST).
--
-- RUN read-only prod safely:
--   1. Run STEP 1 and review the candidate pairs (check overlap_ratio).
--   2. Only then run STEP 2 (the UPDATE). It is idempotent — re-running it
--      changes nothing once the imports are excluded.
--   3. Optionally run STEP 3 to confirm nothing remains.
-- To scope to one user while testing, add  AND g.user_id = '<uuid>'  to the join.

-- ── STEP 1: review candidates (SELECT only, no writes) ──────────────────────
with pairs as (
  select
    g.id          as gps_id,
    i.id          as import_id,
    i.source      as import_source,
    g.started_at  as gps_start,    g.ended_at    as gps_end,
    i.started_at  as import_start, i.ended_at    as import_end,
    extract(epoch from (least(g.ended_at, i.ended_at)
                        - greatest(g.started_at, i.started_at))) as overlap_s,
    extract(epoch from (g.ended_at - g.started_at)) as gps_dur_s,
    extract(epoch from (i.ended_at - i.started_at)) as import_dur_s
  from activities g
  join activities i
    on  i.user_id = g.user_id
    and g.source  = 'phone_gps'
    and i.source  in ('health_connect', 'healthkit')
    and i.excluded = false
    -- Only data from Monday 2026-11-02 (IST) onward — never touch older rows.
    and g.started_at >= timestamptz '2026-11-02 00:00:00+05:30'
    and i.started_at >= timestamptz '2026-11-02 00:00:00+05:30'
    and g.started_at < i.ended_at   -- windows overlap
    and i.started_at < g.ended_at
)
select
  gps_id, import_id, import_source,
  gps_start, gps_end, import_start, import_end,
  round((overlap_s / nullif(least(gps_dur_s, import_dur_s), 0))::numeric, 3) as overlap_ratio
from pairs
where least(gps_dur_s, import_dur_s) > 0
  and overlap_s / least(gps_dur_s, import_dur_s) > 0.7
order by gps_start;

-- ── STEP 2: exclude the superseded imports (WRITE — run only after STEP 1) ──
with pairs as (
  select
    g.id          as gps_id,
    i.id          as import_id,
    extract(epoch from (least(g.ended_at, i.ended_at)
                        - greatest(g.started_at, i.started_at))) as overlap_s,
    extract(epoch from (g.ended_at - g.started_at)) as gps_dur_s,
    extract(epoch from (i.ended_at - i.started_at)) as import_dur_s
  from activities g
  join activities i
    on  i.user_id = g.user_id
    and g.source  = 'phone_gps'
    and i.source  in ('health_connect', 'healthkit')
    and i.excluded = false
    -- Only data from Monday 2026-11-02 (IST) onward — never touch older rows.
    and g.started_at >= timestamptz '2026-11-02 00:00:00+05:30'
    and i.started_at >= timestamptz '2026-11-02 00:00:00+05:30'
    and g.started_at < i.ended_at
    and i.started_at < g.ended_at
)
update activities i
   set excluded     = true,
       dup_group_id = coalesce(i.dup_group_id, p.gps_id)
  from pairs p
 where i.id = p.import_id
   and least(p.gps_dur_s, p.import_dur_s) > 0
   and p.overlap_s / least(p.gps_dur_s, p.import_dur_s) > 0.7;

-- ── STEP 3: verify none remain (SELECT only) ────────────────────────────────
-- Re-run STEP 1; it should return zero rows.
