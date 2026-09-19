-- =====================================================================
-- 07_materialized_views.sql
-- Pay the aggregate cost once, on a schedule, instead of per request.
-- =====================================================================

\timing on
SET search_path = shop, public;

-- =====================================================================
-- A. The query that's killing your dashboard
-- =====================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT
  date_trunc('day', o.created_at)          AS day,
  o.ship_country,
  count(DISTINCT o.id)                     AS orders,
  count(DISTINCT o.user_id)                AS customers,
  sum(oi.qty * oi.unit_cents)              AS revenue_cents
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at >= '2025-01-01'
GROUP BY 1, 2;
-- Seconds. Every dashboard load. From every user. Simultaneously.


-- =====================================================================
-- B. A plain VIEW does not help — it's just a macro
-- =====================================================================

CREATE VIEW daily_sales_view AS
SELECT date_trunc('day', o.created_at) AS day, o.ship_country,
       count(DISTINCT o.id) AS orders, sum(oi.qty*oi.unit_cents) AS revenue_cents
FROM orders o JOIN order_items oi ON oi.order_id = o.id
GROUP BY 1,2;

EXPLAIN (ANALYZE) SELECT * FROM daily_sales_view WHERE day = '2025-05-01';
-- Same plan, same cost. The view is inlined and re-executed every time.


-- =====================================================================
-- C. MATERIALIZED VIEW — results stored on disk
-- =====================================================================

CREATE MATERIALIZED VIEW daily_sales AS
SELECT
  date_trunc('day', o.created_at)::date    AS day,
  o.ship_country,
  count(DISTINCT o.id)                     AS orders,
  count(DISTINCT o.user_id)                AS customers,
  sum(oi.qty * oi.unit_cents)              AS revenue_cents
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
GROUP BY 1, 2
WITH DATA;

-- REQUIRED for REFRESH CONCURRENTLY: a unique index covering every row.
CREATE UNIQUE INDEX idx_daily_sales_pk ON daily_sales (day, ship_country);
CREATE INDEX idx_daily_sales_day ON daily_sales (day DESC);
ANALYZE daily_sales;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM daily_sales WHERE day >= '2025-01-01' ORDER BY day, ship_country;
-- Milliseconds. It's now just a small indexed table.

SELECT pg_size_pretty(pg_total_relation_size('daily_sales')) AS mv_size,
       count(*) AS rows FROM daily_sales;


-- =====================================================================
-- D. Refreshing — and the lock that will take your site down
-- =====================================================================

-- Blocks ALL reads of the MV for the whole rebuild (ACCESS EXCLUSIVE).
REFRESH MATERIALIZED VIEW daily_sales;

-- Builds into a new copy, then swaps. Readers never block.
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_sales;
-- Slower overall and needs 2x disk, but it's the only prod-safe option.
-- Requires the unique index above.

-- Track staleness explicitly, so the UI can say "as of 14:05".
CREATE TABLE mv_refresh_log (
  view_name    text PRIMARY KEY,
  refreshed_at timestamptz NOT NULL,
  duration_ms  integer     NOT NULL
);

CREATE OR REPLACE FUNCTION refresh_mv(v text) RETURNS void AS $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
  EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', v);
  INSERT INTO mv_refresh_log VALUES
    (v, now(), (EXTRACT(epoch FROM clock_timestamp()-t0)*1000)::int)
  ON CONFLICT (view_name) DO UPDATE
    SET refreshed_at = EXCLUDED.refreshed_at, duration_ms = EXCLUDED.duration_ms;
END $$ LANGUAGE plpgsql;

SELECT refresh_mv('daily_sales');
SELECT *, now() - refreshed_at AS staleness FROM mv_refresh_log;

-- Schedule it (pg_cron):
--   CREATE EXTENSION pg_cron;
--   SELECT cron.schedule('refresh-daily-sales', '*/15 * * * *',
--                        $$SELECT shop.refresh_mv('daily_sales')$$);


-- =====================================================================
-- E. The MV's fatal flaw, and the fix: incremental rollups
--
-- REFRESH recomputes the ENTIRE view. Three years of history rebuilt to
-- pick up today's orders. That cost grows forever; your data doesn't shrink.
-- Solution: a real table plus a watermark, updating only what changed.
-- =====================================================================

CREATE TABLE daily_sales_rollup (
  day            date    NOT NULL,
  ship_country   char(2) NOT NULL,
  orders         bigint  NOT NULL,
  customers      bigint  NOT NULL,
  revenue_cents  bigint  NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (day, ship_country)
);

CREATE TABLE rollup_watermark (
  name           text PRIMARY KEY,
  last_order_id  bigint NOT NULL DEFAULT 0
);
INSERT INTO rollup_watermark VALUES ('daily_sales', 0);

CREATE OR REPLACE FUNCTION rollup_daily_sales(batch_size int DEFAULT 500000)
RETURNS TABLE(processed bigint, new_watermark bigint) AS $$
DECLARE lo bigint; hi bigint;
BEGIN
  -- Serialize concurrent runs.
  PERFORM pg_advisory_xact_lock(hashtext('rollup_daily_sales'));

  SELECT last_order_id INTO lo FROM rollup_watermark WHERE name='daily_sales';
  SELECT least(max(id), lo + batch_size) INTO hi FROM orders;
  IF hi IS NULL OR hi <= lo THEN
    RETURN QUERY SELECT 0::bigint, lo; RETURN;
  END IF;

  -- Recompute only the (day, country) buckets touched by the new rows.
  INSERT INTO daily_sales_rollup (day, ship_country, orders, customers, revenue_cents)
  SELECT o.created_at::date, o.ship_country,
         count(DISTINCT o.id), count(DISTINCT o.user_id),
         coalesce(sum(oi.qty * oi.unit_cents), 0)
  FROM orders o
  LEFT JOIN order_items oi ON oi.order_id = o.id
  WHERE (o.created_at::date, o.ship_country) IN (
          SELECT DISTINCT created_at::date, ship_country
          FROM orders WHERE id > lo AND id <= hi)
  GROUP BY 1, 2
  ON CONFLICT (day, ship_country) DO UPDATE SET
    orders        = EXCLUDED.orders,
    customers     = EXCLUDED.customers,
    revenue_cents = EXCLUDED.revenue_cents,
    updated_at    = now();

  UPDATE rollup_watermark SET last_order_id = hi WHERE name='daily_sales';
  RETURN QUERY SELECT (hi - lo), hi;
END $$ LANGUAGE plpgsql;

SELECT * FROM rollup_daily_sales(400000);
SELECT * FROM rollup_daily_sales(400000);   -- picks up where it left off
SELECT count(*), max(updated_at) FROM daily_sales_rollup;

-- Note the design choice: recomputing whole buckets (idempotent, self-healing)
-- rather than adding deltas (fast, but drifts permanently if a batch runs twice).
-- Only use additive deltas when you also have a periodic full-recompute job.

-- Reconciliation, same discipline as step 02:
SELECT r.day, r.ship_country, r.revenue_cents AS rollup, m.revenue_cents AS truth
FROM daily_sales_rollup r
JOIN daily_sales m USING (day, ship_country)
WHERE r.revenue_cents IS DISTINCT FROM m.revenue_cents
LIMIT 20;


-- =====================================================================
-- F. Choosing between the three precomputation patterns
--
--                  freshness    write cost   read cost   complexity
--   plain VIEW     perfect      none         high        none
--   counter (02)   perfect      per-write    lowest      medium (triggers)
--   MAT VIEW       minutes      none         low         low
--   rollup (E)     seconds      none         low         high
--
--   Use a counter when the read must be transactionally consistent.
--   Use a MAT VIEW when a full rebuild fits in your refresh window.
--   Use a rollup table when it no longer does.
--   Use TimescaleDB continuous aggregates if you'd rather not maintain E.
-- =====================================================================
