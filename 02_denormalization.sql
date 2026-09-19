-- =====================================================================
-- 02_denormalization.sql
-- Trading write cost and correctness risk for read speed.
-- Only do this after indexing has stopped being enough.
-- =====================================================================

\timing on
SET search_path = shop, public;

-- =====================================================================
-- A. The problem: a join + aggregate on every single read
-- =====================================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, count(oi.id) AS items, sum(oi.qty * oi.unit_cents) AS total
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.user_id = 7
GROUP BY o.id, o.status;
-- Needs an index on order_items.order_id first, otherwise it's brutal:
CREATE INDEX IF NOT EXISTS idx_items_order ON order_items (order_id);
ANALYZE order_items;
-- Re-run the EXPLAIN. Better — but still N index lookups + aggregation
-- on every order-list page render, forever.


-- =====================================================================
-- B. Denormalization #1: precomputed totals on the parent row
-- =====================================================================

ALTER TABLE orders
  ADD COLUMN item_count  integer NOT NULL DEFAULT 0,
  ADD COLUMN total_cents bigint  NOT NULL DEFAULT 0;

-- Backfill in batches so you don't hold one giant transaction.
-- (In prod: loop this in the app, 10k ids at a time, commit each batch.)
WITH agg AS (
  SELECT order_id, count(*) AS c, sum(qty * unit_cents) AS t
  FROM order_items GROUP BY order_id
)
UPDATE orders o
SET item_count = agg.c, total_cents = agg.t
FROM agg WHERE agg.order_id = o.id;

-- Keep it correct on every write.
CREATE OR REPLACE FUNCTION sync_order_totals() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE orders SET
      item_count  = item_count  + 1,
      total_cents = total_cents + NEW.qty * NEW.unit_cents
    WHERE id = NEW.order_id;

  ELSIF TG_OP = 'DELETE' THEN
    UPDATE orders SET
      item_count  = item_count  - 1,
      total_cents = total_cents - OLD.qty * OLD.unit_cents
    WHERE id = OLD.order_id;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Handle the item moving between orders.
    IF OLD.order_id <> NEW.order_id THEN
      UPDATE orders SET item_count = item_count - 1,
             total_cents = total_cents - OLD.qty * OLD.unit_cents
      WHERE id = OLD.order_id;
      UPDATE orders SET item_count = item_count + 1,
             total_cents = total_cents + NEW.qty * NEW.unit_cents
      WHERE id = NEW.order_id;
    ELSE
      UPDATE orders SET
        total_cents = total_cents
                    - OLD.qty * OLD.unit_cents
                    + NEW.qty * NEW.unit_cents
      WHERE id = NEW.order_id;
    END IF;
  END IF;
  RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_order_totals
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION sync_order_totals();

ANALYZE orders;

-- The read is now a single-table index scan. No join, no aggregate.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, item_count, total_cents
FROM orders WHERE user_id = 7;

-- Prove the trigger works:
INSERT INTO order_items VALUES (99000001, 7, 5, 2, 1000);
SELECT id, item_count, total_cents FROM orders WHERE id = 7;
DELETE FROM order_items WHERE id = 99000001;
SELECT id, item_count, total_cents FROM orders WHERE id = 7;


-- =====================================================================
-- C. The cost you just took on
-- =====================================================================

-- 1. Write amplification: every item write now also writes the order row.
--    Measure it.
EXPLAIN (ANALYZE) INSERT INTO order_items VALUES (99000002, 12345, 5, 1, 999);
DELETE FROM order_items WHERE id = 99000002;

-- 2. Lock contention: concurrent inserts into the SAME order serialize on
--    that one orders row. Fine for orders (few items each).
--    Fatal for "likes on a viral post" — there you need a counter-delta table:
--
--      CREATE TABLE post_like_deltas (post_id bigint, delta int, ...);
--      -- insert +1 rows, never update a shared row
--      -- a periodic job folds deltas into posts.like_count
--
-- 3. Drift. Triggers get bypassed by COPY paths, bulk fixes, replication
--    edge cases. So you need a reconciliation query you run on a schedule:

CREATE OR REPLACE VIEW order_totals_drift AS
SELECT
  o.id,
  o.item_count  AS cached_count,
  a.c           AS real_count,
  o.total_cents AS cached_total,
  a.t           AS real_total
FROM orders o
LEFT JOIN (
  SELECT order_id, count(*) c, sum(qty*unit_cents) t
  FROM order_items GROUP BY order_id
) a ON a.order_id = o.id
WHERE o.item_count IS DISTINCT FROM coalesce(a.c, 0)
   OR o.total_cents IS DISTINCT FROM coalesce(a.t, 0);

SELECT count(*) AS drifted_orders FROM order_totals_drift;  -- must be 0


-- =====================================================================
-- D. Denormalization #2: copy a dimension to kill a join
-- =====================================================================

-- Analytics constantly joins orders -> users just to get country.
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.country, count(*)
FROM orders o JOIN users u ON u.id = o.user_id
WHERE o.created_at >= '2025-01-01'
GROUP BY u.country;

ALTER TABLE orders ADD COLUMN user_country char(2);
UPDATE orders o SET user_country = u.country FROM users u WHERE u.id = o.user_id;
CREATE INDEX idx_orders_created_country ON orders (created_at, user_country);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT user_country, count(*)
FROM orders WHERE created_at >= '2025-01-01'
GROUP BY user_country;
-- One table. No hash join, no 200k-row build side.
--
-- Safe here because a country is copied at order time and SHOULD NOT change
-- retroactively when the user moves. Copying a *mutable* attribute you expect
-- to stay in sync is where this pattern turns into a bug factory.


-- =====================================================================
-- E. Denormalization #3: snapshotting (correctness, not just speed)
-- =====================================================================

-- order_items already stores unit_cents instead of joining products.price_cents.
-- That is denormalization done for the right reason: the price at purchase time
-- is a FACT about the order, not a lookup. Never "normalize" this away.

-- Same idea, wider: freeze the whole product shape at purchase time.
ALTER TABLE order_items ADD COLUMN product_snapshot jsonb;

UPDATE order_items oi
SET product_snapshot = jsonb_build_object(
      'sku', p.sku, 'name', p.name, 'category', p.category)
FROM products p
WHERE p.id = oi.product_id
  AND oi.order_id BETWEEN 1 AND 1000;   -- partial: demo only

SELECT id, product_id, product_snapshot
FROM order_items WHERE order_id = 7;


-- =====================================================================
-- Decision rule
--   Read:write ratio high + join is hot           -> denormalize
--   Value is a point-in-time fact                 -> denormalize, always
--   High write concurrency on one parent row      -> delta table, not a counter
--   You cannot write the drift-check query        -> don't denormalize yet
-- =====================================================================
