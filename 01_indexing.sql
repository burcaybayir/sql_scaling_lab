-- =====================================================================
-- 01_indexing.sql
-- The cheapest 100x you will ever get. Run each block, read the plan,
-- THEN create the index. Watching the plan change is the whole point.
-- =====================================================================

\timing on
SET search_path = shop, public;

-- =====================================================================
-- A. The baseline: no index, sequential scan
-- =====================================================================

-- Pick a user who actually has orders.
SELECT user_id, count(*) FROM orders GROUP BY 1 ORDER BY 2 DESC LIMIT 1;  -- note the id

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id = 7;
-- Seq Scan on orders ... rows=2000000 ... shared read=~20000 blocks
-- ~150-400ms. Postgres read 160MB to return ~10 rows.

CREATE INDEX idx_orders_user ON orders (user_id);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id = 7;
-- Index Scan using idx_orders_user ... shared read=~5 blocks. <1ms.
-- Lesson: cost scales with blocks touched, not with table size.


-- =====================================================================
-- B. Composite indexes: column ORDER is not cosmetic
-- =====================================================================

-- Query pattern: one user's recent orders.
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE user_id = 7 AND created_at >= '2024-06-01'
ORDER BY created_at DESC
LIMIT 20;
-- Uses idx_orders_user, then filters + sorts. Fine here, bad for whales.

CREATE INDEX idx_orders_user_created ON orders (user_id, created_at DESC);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders
WHERE user_id = 7 AND created_at >= '2024-06-01'
ORDER BY created_at DESC
LIMIT 20;
-- Now: Index Scan, NO Sort node at all. The index IS the sort order.

-- Now the wrong order, same columns:
CREATE INDEX idx_orders_created_user ON orders (created_at DESC, user_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id = 7 ORDER BY created_at DESC LIMIT 20;
-- Planner ignores idx_orders_created_user for this. An equality predicate
-- must sit on the LEFT of the index, or you can't seek — only scan.
--
-- RULE: equality columns first, then the range/sort column. "ESR".

DROP INDEX idx_orders_created_user;   -- dead weight, costs you on every write
DROP INDEX idx_orders_user;           -- now fully redundant: it's a prefix of the composite


-- =====================================================================
-- C. Covering indexes → Index Only Scan
-- =====================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, created_at, status FROM orders WHERE user_id BETWEEN 100 AND 200;
-- Index Scan + heap fetches: one random heap read per matching row.

CREATE INDEX idx_orders_user_covering
  ON orders (user_id, created_at) INCLUDE (status);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, created_at, status FROM orders WHERE user_id BETWEEN 100 AND 200;
-- "Index Only Scan ... Heap Fetches: 0" — the table is never touched.
--
-- Heap Fetches > 0 means the visibility map is stale. Fix: VACUUM orders;
-- INCLUDE columns are payload only — you cannot filter on them efficiently.


-- =====================================================================
-- D. Partial indexes: index the 1% you query, not the 99% you don't
-- =====================================================================

SELECT status, count(*), round(100.0*count(*)/sum(count(*)) OVER (), 2) AS pct
FROM orders GROUP BY 1 ORDER BY 2 DESC;
-- 'completed' ~97%, 'pending' ~1%.

-- Full index on status: ~14 MB, and useless for 'completed'
-- (the planner will seq-scan anyway — 97% of rows is not selective).
CREATE INDEX idx_orders_status_full ON orders (status);
SELECT pg_size_pretty(pg_relation_size('idx_orders_status_full'));

-- Partial index: only the rows a "pending orders" job cares about.
CREATE INDEX idx_orders_pending
  ON orders (created_at)
  WHERE status = 'pending';
SELECT pg_size_pretty(pg_relation_size('idx_orders_pending'));
-- ~1% the size, and it stays tiny because rows LEAVE the index when
-- status changes to 'completed'. Perfect for queue/outbox tables.

ANALYZE orders;
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at LIMIT 50;

DROP INDEX idx_orders_status_full;


-- =====================================================================
-- E. Expression indexes: match what the query actually computes
-- =====================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1234@corp.io';
-- Seq Scan. An index on (email) cannot help — lower(email) is a different value.

CREATE INDEX idx_users_lower_email ON users (lower(email));
ANALYZE users;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM users WHERE lower(email) = 'user1234@corp.io';
-- Index Scan. The indexed expression must match the query expression EXACTLY.

-- Same trap with dates:
--   WHERE date(created_at) = '2024-01-01'         -> no index use
--   WHERE created_at >= '2024-01-01'
--     AND created_at <  '2024-01-02'              -> index use
-- Prefer rewriting the query over adding an expression index.


-- =====================================================================
-- F. GIN for jsonb and text search
-- =====================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM users WHERE profile @> '{"tier":"pro"}';

CREATE INDEX idx_users_profile ON users USING gin (profile jsonb_path_ops);
ANALYZE users;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM users WHERE profile @> '{"tier":"pro"}';
-- Bitmap Index Scan on GIN.
-- jsonb_path_ops is smaller/faster than default but only supports @>.

-- Fuzzy/substring search: B-tree can't do LIKE '%foo%'. Trigrams can.
CREATE INDEX idx_products_name_trgm ON products USING gin (name gin_trgm_ops);
ANALYZE products;
EXPLAIN (ANALYZE) SELECT * FROM products WHERE name LIKE '%1234%';


-- =====================================================================
-- G. BRIN: 1000x smaller than B-tree on naturally ordered data
-- =====================================================================

-- order_items.id correlates almost perfectly with physical row order
-- because we inserted sequentially. BRIN stores min/max per 128-page range.
CREATE INDEX idx_items_order_brin ON order_items USING brin (order_id)
  WITH (pages_per_range = 64);

SELECT
  pg_size_pretty(pg_relation_size('idx_items_order_brin')) AS brin_size;
-- Kilobytes, vs ~100MB for the equivalent B-tree.

ANALYZE order_items;
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM order_items WHERE order_id BETWEEN 1500000 AND 1500100;
-- Bitmap Heap Scan with "Rows Removed by Index Recheck" — BRIN is lossy.
-- Great for append-only logs/time-series. Useless if the column is random.

-- Check correlation before reaching for BRIN:
SELECT attname, correlation FROM pg_stats
WHERE schemaname='shop' AND tablename='order_items';
-- |correlation| near 1.0 -> BRIN works. Near 0 -> it won't.


-- =====================================================================
-- H. Finding the indexes you should delete
-- =====================================================================

-- Unused indexes still cost you on every INSERT/UPDATE/DELETE.
SELECT
  s.relname AS table_name,
  s.indexrelname AS index_name,
  s.idx_scan AS times_used,
  pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.schemaname = 'shop'
  AND NOT i.indisunique
ORDER BY s.idx_scan, pg_relation_size(s.indexrelid) DESC;
-- idx_scan = 0 after a full traffic cycle (a week, not an hour) -> drop it.

-- Cache hit ratio per index; low ratio = index doesn't fit in RAM.
SELECT
  indexrelname,
  idx_blks_hit,
  idx_blks_read,
  round(100.0 * idx_blks_hit / nullif(idx_blks_hit + idx_blks_read, 0), 2) AS hit_pct
FROM pg_statio_user_indexes
WHERE schemaname = 'shop'
ORDER BY idx_blks_read DESC;


-- =====================================================================
-- I. Building indexes in production without locking writes
-- =====================================================================

-- Blocks all writes to the table for the duration. Never do this in prod.
--   CREATE INDEX idx_x ON big_table (col);

-- Two table scans, no write lock. Cannot run inside a transaction block.
CREATE INDEX CONCURRENTLY idx_items_product ON order_items (product_id);

-- CONCURRENTLY can fail and leave an INVALID index behind. Always check:
SELECT indexrelid::regclass AS idx
FROM pg_index WHERE NOT indisvalid;
-- If any: DROP INDEX CONCURRENTLY <idx>; and retry.

-- Rebuild a bloated index with no downtime:
--   REINDEX INDEX CONCURRENTLY idx_items_product;

ANALYZE;

-- =====================================================================
-- Where indexing stops working
--   * write-heavy tables — every index multiplies write cost
--   * the working set no longer fits in shared_buffers -> go to step 06
--   * index maintenance itself becomes the bottleneck -> go to step 05
--   * the query is an aggregate over millions of rows -> go to step 07
-- =====================================================================
