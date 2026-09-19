-- =====================================================================
-- bench/benchmarks.sql
-- Runs each technique twice: once without the optimization, once with.
-- Self-contained — it creates and drops everything it needs, so it can
-- run against a fresh 00_setup.sql load with no other steps applied.
--
--   psql "$PGURL" -f bench/harness.sql -f bench/benchmarks.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = shop, bench, public;
SET jit = off;                        -- keeps small-query timings comparable

-- =====================================================================
-- 01 INDEXING
-- =====================================================================

DROP INDEX IF EXISTS idx_orders_user_created;
DROP INDEX IF EXISTS idx_orders_pending;
DROP INDEX IF EXISTS idx_users_lower_email;
ANALYZE orders; ANALYZE users;

SELECT bench.measure('01 Indexing', 'Point lookup by user_id', 'before',
  $q$ SELECT * FROM shop.orders WHERE user_id = 7 $q$);

SELECT bench.measure('01 Indexing', 'Recent orders, sorted', 'before',
  $q$ SELECT * FROM shop.orders WHERE user_id = 7
      ORDER BY created_at DESC LIMIT 20 $q$);

SELECT bench.measure('01 Indexing', 'Pending queue drain', 'before',
  $q$ SELECT * FROM shop.orders WHERE status = 'pending'
      ORDER BY created_at LIMIT 50 $q$);

SELECT bench.measure('01 Indexing', 'Case-insensitive email', 'before',
  $q$ SELECT * FROM shop.users WHERE lower(email) = 'user1234@corp.io' $q$);

CREATE INDEX idx_orders_user_created ON shop.orders (user_id, created_at DESC);
CREATE INDEX idx_orders_pending ON shop.orders (created_at) WHERE status = 'pending';
CREATE INDEX idx_users_lower_email ON shop.users (lower(email));
ANALYZE orders; ANALYZE users;

SELECT bench.measure('01 Indexing', 'Point lookup by user_id', 'after',
  $q$ SELECT * FROM shop.orders WHERE user_id = 7 $q$);

SELECT bench.measure('01 Indexing', 'Recent orders, sorted', 'after',
  $q$ SELECT * FROM shop.orders WHERE user_id = 7
      ORDER BY created_at DESC LIMIT 20 $q$);

SELECT bench.measure('01 Indexing', 'Pending queue drain', 'after',
  $q$ SELECT * FROM shop.orders WHERE status = 'pending'
      ORDER BY created_at LIMIT 50 $q$);

SELECT bench.measure('01 Indexing', 'Case-insensitive email', 'after',
  $q$ SELECT * FROM shop.users WHERE lower(email) = 'user1234@corp.io' $q$);


-- =====================================================================
-- 02 DENORMALIZATION
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_items_order ON shop.order_items (order_id);
ANALYZE order_items;

SELECT bench.measure('02 Denormalization', 'Order totals for one user', 'before',
  $q$ SELECT o.id, count(oi.id) AS items, sum(oi.qty*oi.unit_cents) AS total
      FROM shop.orders o JOIN shop.order_items oi ON oi.order_id = o.id
      WHERE o.user_id = 7 GROUP BY o.id $q$);

SELECT bench.measure('02 Denormalization', 'Orders per country, 1 year', 'before',
  $q$ SELECT u.country, count(*) FROM shop.orders o
      JOIN shop.users u ON u.id = o.user_id
      WHERE o.created_at >= '2025-01-01' GROUP BY u.country $q$);

ALTER TABLE shop.orders
  ADD COLUMN IF NOT EXISTS item_count int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_cents bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user_country char(2);

WITH agg AS (
  SELECT order_id, count(*) c, sum(qty*unit_cents) t
  FROM shop.order_items GROUP BY order_id)
UPDATE shop.orders o SET item_count = agg.c, total_cents = agg.t
FROM agg WHERE agg.order_id = o.id;

UPDATE shop.orders o SET user_country = u.country
FROM shop.users u WHERE u.id = o.user_id;

CREATE INDEX IF NOT EXISTS idx_orders_created_country
  ON shop.orders (created_at, user_country);
ANALYZE orders;

SELECT bench.measure('02 Denormalization', 'Order totals for one user', 'after',
  $q$ SELECT id, item_count, total_cents FROM shop.orders WHERE user_id = 7 $q$);

SELECT bench.measure('02 Denormalization', 'Orders per country, 1 year', 'after',
  $q$ SELECT user_country, count(*) FROM shop.orders
      WHERE created_at >= '2025-01-01' GROUP BY user_country $q$);


-- =====================================================================
-- 03 CACHING (result cache table vs recomputing)
-- =====================================================================

CREATE UNLOGGED TABLE IF NOT EXISTS shop.query_cache (
  key text PRIMARY KEY, value jsonb NOT NULL, expires_at timestamptz NOT NULL);

SELECT bench.measure('03 Caching', 'Country stats aggregate', 'before',
  $q$ SELECT jsonb_agg(x) FROM (
        SELECT user_country, count(*) c FROM shop.orders
        WHERE created_at >= now() - interval '365 days'
        GROUP BY user_country) x $q$);

INSERT INTO shop.query_cache (key, value, expires_at)
SELECT 'country_stats',
       (SELECT jsonb_agg(x) FROM (
          SELECT user_country, count(*) c FROM shop.orders
          WHERE created_at >= now() - interval '365 days'
          GROUP BY user_country) x),
       now() + interval '1 hour'
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value,
                                expires_at = EXCLUDED.expires_at;
ANALYZE shop.query_cache;

SELECT bench.measure('03 Caching', 'Country stats aggregate', 'after',
  $q$ SELECT value FROM shop.query_cache
      WHERE key = 'country_stats' AND expires_at > now() $q$);


-- =====================================================================
-- 05 SHARDING (single-node partitioning + pruning)
-- =====================================================================

DROP TABLE IF EXISTS shop.orders_part CASCADE;
CREATE TABLE shop.orders_part (
  id bigint NOT NULL, user_id bigint NOT NULL, status text NOT NULL,
  created_at timestamptz NOT NULL, ship_country char(2) NOT NULL,
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

DO $$ DECLARE d date := '2023-01-01';
BEGIN
  WHILE d < '2026-01-01' LOOP
    EXECUTE format('CREATE TABLE shop.orders_p%s PARTITION OF shop.orders_part
                    FOR VALUES FROM (%L) TO (%L)',
                   to_char(d,'YYYY_"q"Q'), d, d + interval '3 months');
    d := d + interval '3 months';
  END LOOP;
END $$;
CREATE TABLE shop.orders_pdefault PARTITION OF shop.orders_part DEFAULT;

INSERT INTO shop.orders_part
SELECT id, user_id, status, created_at, ship_country FROM shop.orders;
ANALYZE shop.orders_part;

SELECT bench.measure('05 Sharding', 'One quarter of history', 'before',
  $q$ SELECT count(*), max(created_at) FROM shop.orders
      WHERE created_at >= '2025-04-01' AND created_at < '2025-07-01' $q$);

SELECT bench.measure('05 Sharding', 'One quarter of history', 'after',
  $q$ SELECT count(*), max(created_at) FROM shop.orders_part
      WHERE created_at >= '2025-04-01' AND created_at < '2025-07-01' $q$);


-- =====================================================================
-- 06 VERTICAL SCALING (work_mem: disk spill vs in-memory sort)
-- =====================================================================

SET work_mem = '1MB';
SELECT bench.measure('06 Vertical scaling', 'Top orders by value (sort)', 'before',
  $q$ SELECT order_id, sum(qty*unit_cents) t FROM shop.order_items
      GROUP BY order_id ORDER BY t DESC LIMIT 100 $q$, 3);

SET work_mem = '256MB';
SELECT bench.measure('06 Vertical scaling', 'Top orders by value (sort)', 'after',
  $q$ SELECT order_id, sum(qty*unit_cents) t FROM shop.order_items
      GROUP BY order_id ORDER BY t DESC LIMIT 100 $q$, 3);
RESET work_mem;


-- =====================================================================
-- 07 MATERIALIZED VIEWS
-- =====================================================================

DROP MATERIALIZED VIEW IF EXISTS shop.daily_sales;

SELECT bench.measure('07 Materialized views', 'Daily sales dashboard', 'before',
  $q$ SELECT date_trunc('day', o.created_at)::date d, o.ship_country,
             count(DISTINCT o.id), sum(oi.qty*oi.unit_cents)
      FROM shop.orders o JOIN shop.order_items oi ON oi.order_id = o.id
      WHERE o.created_at >= '2025-01-01' GROUP BY 1,2 $q$, 3);

CREATE MATERIALIZED VIEW shop.daily_sales AS
SELECT date_trunc('day', o.created_at)::date AS day, o.ship_country,
       count(DISTINCT o.id) AS orders, count(DISTINCT o.user_id) AS customers,
       sum(oi.qty*oi.unit_cents) AS revenue_cents
FROM shop.orders o JOIN shop.order_items oi ON oi.order_id = o.id
GROUP BY 1,2;
CREATE UNIQUE INDEX idx_daily_sales_pk ON shop.daily_sales (day, ship_country);
ANALYZE shop.daily_sales;

SELECT bench.measure('07 Materialized views', 'Daily sales dashboard', 'after',
  $q$ SELECT day, ship_country, orders, revenue_cents FROM shop.daily_sales
      WHERE day >= '2025-01-01' $q$, 3);


-- =====================================================================
\echo ''
\echo '=== RESULTS ==='
SELECT bench.report();
