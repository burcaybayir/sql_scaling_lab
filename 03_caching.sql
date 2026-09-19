-- =====================================================================
-- 03_caching.sql
-- Four different caches, four different failure modes.
-- =====================================================================

\timing on
SET search_path = shop, public;

-- =====================================================================
-- A. Layer 1: the buffer cache you already have
-- =====================================================================

SELECT pg_stat_statements_reset();
SELECT
  sum(heap_blks_hit)  AS from_cache,
  sum(heap_blks_read) AS from_disk,
  round(100.0*sum(heap_blks_hit)/nullif(sum(heap_blks_hit)+sum(heap_blks_read),0), 2) AS hit_pct
FROM pg_statio_user_tables WHERE schemaname = 'shop';
-- Under ~95% on an OLTP workload means you are disk-bound. Two fixes:
-- raise shared_buffers (step 06) or read fewer blocks (step 01).

-- Cold-start problem: after a restart the cache is empty and everything
-- is slow for 20 minutes. Warm it deliberately:
SELECT pg_prewarm('shop.orders');
SELECT pg_prewarm('shop.idx_orders_user_created');

-- What is actually resident right now (needs pg_buffercache):
--   CREATE EXTENSION pg_buffercache;
--   SELECT c.relname, count(*)*8192/1024/1024 AS mb_cached
--   FROM pg_buffercache b JOIN pg_class c ON c.oid = b.relfilenode
--   GROUP BY 1 ORDER BY 2 DESC LIMIT 10;


-- =====================================================================
-- B. Layer 2: plan caching via prepared statements
-- =====================================================================

-- Parsing + planning is real cost on short queries.
PREPARE user_orders (bigint) AS
  SELECT id, status, created_at FROM orders
  WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20;

EXPLAIN (ANALYZE) EXECUTE user_orders(7);
EXECUTE user_orders(7);
EXECUTE user_orders(99);
EXECUTE user_orders(1234);
EXECUTE user_orders(4321);
EXECUTE user_orders(5555);
-- On the 6th execution Postgres may switch to a GENERIC plan (no parameter
-- knowledge). Usually good. Sometimes catastrophic on skewed columns —
-- our user_id is Zipfian, so a whale and a one-order user want different plans.

-- Force the behaviour you want:
SET plan_cache_mode = 'force_custom_plan';    -- replan every time, skew-safe
-- SET plan_cache_mode = 'force_generic_plan'; -- never replan, cheapest
-- SET plan_cache_mode = 'auto';               -- default
EXPLAIN (ANALYZE) EXECUTE user_orders(7);

DEALLOCATE user_orders;
RESET plan_cache_mode;


-- =====================================================================
-- C. Layer 3: an explicit result cache table
--    (the pattern Redis implements — useful to see it in SQL first)
-- =====================================================================

CREATE UNLOGGED TABLE query_cache (      -- UNLOGGED: no WAL, it's disposable
  key        text PRIMARY KEY,
  value      jsonb       NOT NULL,
  expires_at timestamptz NOT NULL
);
CREATE INDEX idx_query_cache_exp ON query_cache (expires_at);

-- The expensive thing we want to avoid repeating.
CREATE OR REPLACE FUNCTION compute_country_stats() RETURNS jsonb AS $$
  SELECT jsonb_agg(jsonb_build_object('country', user_country, 'orders', c))
  FROM (
    SELECT user_country, count(*) c
    FROM orders WHERE created_at >= now() - interval '365 days'
    GROUP BY user_country
  ) s;
$$ LANGUAGE sql STABLE;

-- Read-through cache with stampede protection.
CREATE OR REPLACE FUNCTION cached_country_stats(ttl interval DEFAULT '5 minutes')
RETURNS jsonb AS $$
DECLARE
  v jsonb;
  k text := 'country_stats';
BEGIN
  SELECT value INTO v FROM query_cache
   WHERE key = k AND expires_at > now();
  IF FOUND THEN RETURN v; END IF;

  -- Stampede guard: only ONE session recomputes; the rest wait here and
  -- then find the fresh value. Without this, a cache expiry under load
  -- fires N identical expensive queries simultaneously.
  IF NOT pg_try_advisory_xact_lock(hashtext(k)) THEN
    PERFORM pg_advisory_xact_lock(hashtext(k));
    SELECT value INTO v FROM query_cache WHERE key = k AND expires_at > now();
    IF FOUND THEN RETURN v; END IF;
  END IF;

  v := compute_country_stats();
  INSERT INTO query_cache (key, value, expires_at)
  VALUES (k, v, now() + ttl)
  ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at;
  RETURN v;
END $$ LANGUAGE plpgsql;

SELECT cached_country_stats();   -- cold: slow
SELECT cached_country_stats();   -- warm: microseconds
SELECT cached_country_stats();

-- Janitor (run from cron / pg_cron):
DELETE FROM query_cache WHERE expires_at < now();


-- =====================================================================
-- D. Layer 4: event-driven invalidation instead of TTL
--    TTL means "stale for up to N minutes". NOTIFY means "stale for ~0ms".
-- =====================================================================

CREATE OR REPLACE FUNCTION invalidate_order_caches() RETURNS trigger AS $$
BEGIN
  -- Tell every listening app process to drop its local copy.
  PERFORM pg_notify('cache_invalidate',
    json_build_object(
      'entity', 'orders',
      'user_id', coalesce(NEW.user_id, OLD.user_id),
      'at', now()
    )::text);

  DELETE FROM query_cache WHERE key = 'country_stats';
  RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_invalidate_order_caches
AFTER INSERT OR UPDATE OR DELETE ON orders
FOR EACH STATEMENT EXECUTE FUNCTION invalidate_order_caches();
-- FOR EACH STATEMENT, not FOR EACH ROW: one notify per batch, not per row.

-- In one psql session:
--   LISTEN cache_invalidate;
-- In another:
--   INSERT INTO shop.orders VALUES (99000001, 7, 'pending', now(), 'TR');
-- The first session prints the payload. That's your invalidation bus.

-- Caveats before you ship this:
--   * NOTIFY fires at COMMIT, and is lost if no one is listening
--   * payload limit is 8000 bytes
--   * it does not survive a failover — treat it as an optimization,
--     always keep a TTL as the backstop


-- =====================================================================
-- E. Where each layer belongs
--   buffer cache   — always on, tune via shared_buffers
--   plan cache     — free, watch out for generic plans on skewed columns
--   result cache   — expensive aggregates, tolerate seconds of staleness
--   NOTIFY         — cut staleness to ~0, never rely on it alone
--   Redis/Memcached— same as the result cache, but off the DB's CPU and
--                    survives DB restarts. Move here once query_cache
--                    contention shows up in pg_stat_statements.
-- =====================================================================

SELECT calls, round(mean_exec_time::numeric, 2) AS avg_ms, query
FROM pg_stat_statements
WHERE query ILIKE '%country_stats%'
ORDER BY total_exec_time DESC LIMIT 5;
