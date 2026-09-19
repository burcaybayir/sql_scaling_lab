-- =====================================================================
-- 05_sharding.sql
-- Part 1: partitioning (sharding within one node) — do this first, always.
-- Part 2: real sharding across nodes with postgres_fdw.
-- =====================================================================

\timing on
SET search_path = shop, public;

-- =====================================================================
-- PART 1 — DECLARATIVE PARTITIONING
-- =====================================================================

-- A. RANGE partitioning by time: the default choice for event data.

CREATE TABLE orders_part (
  id           bigint      NOT NULL,
  user_id      bigint      NOT NULL,
  status       text        NOT NULL,
  created_at   timestamptz NOT NULL,
  ship_country char(2)     NOT NULL,
  PRIMARY KEY (id, created_at)        -- partition key MUST be in the PK
) PARTITION BY RANGE (created_at);

-- Generate quarterly partitions for 2023-2025.
DO $$
DECLARE d date := '2023-01-01';
BEGIN
  WHILE d < '2026-01-01' LOOP
    EXECUTE format(
      'CREATE TABLE orders_p%s PARTITION OF orders_part FOR VALUES FROM (%L) TO (%L)',
      to_char(d, 'YYYY_"q"Q'), d, d + interval '3 months');
    d := d + interval '3 months';
  END LOOP;
END $$;

-- Always have a catch-all so an out-of-range insert doesn't error.
CREATE TABLE orders_default PARTITION OF orders_part DEFAULT;

INSERT INTO orders_part (id, user_id, status, created_at, ship_country)
SELECT id, user_id, status, created_at, ship_country FROM orders;

CREATE INDEX ON orders_part (user_id, created_at DESC);  -- cascades to all partitions
ANALYZE orders_part;

SELECT
  c.relname,
  to_char(c.reltuples::bigint, '999,999,999') AS est_rows,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE i.inhparent = 'orders_part'::regclass
ORDER BY c.relname;


-- B. Partition pruning — the actual payoff

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders_part
WHERE created_at >= '2025-04-01' AND created_at < '2025-07-01';
-- "Partitions removed by pruning" / only ONE scan node.
-- Compare against the unpartitioned table:
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders WHERE created_at >= '2025-04-01' AND created_at < '2025-07-01';

-- Pruning FAILS silently when the predicate hides the key:
EXPLAIN (COSTS OFF)
SELECT count(*) FROM orders_part WHERE date(created_at) = '2025-05-01';
-- scans every partition. Always compare the raw column against constants.

-- Run-time pruning with a parameter:
PREPARE p (timestamptz) AS SELECT count(*) FROM orders_part WHERE created_at >= $1;
EXPLAIN (ANALYZE) EXECUTE p('2025-01-01');
DEALLOCATE p;


-- C. The operational win people forget: instant data lifecycle

-- Dropping a quarter of data: milliseconds, no bloat, no VACUUM.
BEGIN;
  ALTER TABLE orders_part DETACH PARTITION orders_p2023_q1 CONCURRENTLY;
COMMIT;
-- DROP TABLE orders_p2023_q1;         -- or archive it to cold storage
-- vs. DELETE FROM orders WHERE created_at < '2023-04-01' -> hours + 40GB of bloat

-- Attaching new data with validation done up front:
CREATE TABLE orders_p2026_q1 (LIKE orders_part INCLUDING ALL);
ALTER TABLE orders_p2026_q1 ADD CONSTRAINT ck
  CHECK (created_at >= '2026-01-01' AND created_at < '2026-04-01') NOT VALID;
ALTER TABLE orders_p2026_q1 VALIDATE CONSTRAINT ck;   -- scan happens here, no lock on parent
ALTER TABLE orders_part ATTACH PARTITION orders_p2026_q1
  FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');   -- instant


-- D. HASH partitioning: spread write load, no natural time key

CREATE TABLE users_part (
  id        bigint PRIMARY KEY,
  email     text   NOT NULL,
  country   char(2) NOT NULL,
  signup_at timestamptz NOT NULL
) PARTITION BY HASH (id);

CREATE TABLE users_h0 PARTITION OF users_part FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE users_h1 PARTITION OF users_part FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE users_h2 PARTITION OF users_part FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE users_h3 PARTITION OF users_part FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO users_part SELECT id, email, country, signup_at FROM users;
ANALYZE users_part;

SELECT tableoid::regclass AS partition, count(*)
FROM users_part GROUP BY 1 ORDER BY 1;    -- should be ~even

-- Hash gives even distribution but NO range pruning. A query without id
-- touches all 4. Changing MODULUS later requires rewriting everything —
-- pick a number with many divisors (e.g. 64) and merge, don't resplit.


-- =====================================================================
-- PART 2 — SHARDING ACROSS NODES (postgres_fdw)
-- Start the shard nodes:  docker compose up -d pg-shard0 pg-shard1
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgres_fdw;

CREATE SERVER shard0 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'pg-shard0', port '5432', dbname 'shard0',
           fetch_size '10000', async_capable 'true');
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'pg-shard1', port '5432', dbname 'shard1',
           fetch_size '10000', async_capable 'true');

CREATE USER MAPPING FOR CURRENT_USER SERVER shard0
  OPTIONS (user 'postgres', password 'lab');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard1
  OPTIONS (user 'postgres', password 'lab');

-- On EACH shard node, create the physical table first:
--   docker exec -it pg-shard0 psql -U postgres -d shard0 -c "
--     CREATE TABLE orders_shard (
--       id bigint NOT NULL, user_id bigint NOT NULL, status text NOT NULL,
--       created_at timestamptz NOT NULL, ship_country char(2) NOT NULL,
--       PRIMARY KEY (id, user_id));
--     CREATE INDEX ON orders_shard (user_id, created_at DESC);"
--   (same on pg-shard1 / dbname shard1)

-- Coordinator: a partitioned table whose partitions live on other machines.
CREATE TABLE orders_sharded (
  id           bigint      NOT NULL,
  user_id      bigint      NOT NULL,
  status       text        NOT NULL,
  created_at   timestamptz NOT NULL,
  ship_country char(2)     NOT NULL
) PARTITION BY HASH (user_id);

CREATE FOREIGN TABLE orders_s0 PARTITION OF orders_sharded
  FOR VALUES WITH (MODULUS 2, REMAINDER 0)
  SERVER shard0 OPTIONS (table_name 'orders_shard');

CREATE FOREIGN TABLE orders_s1 PARTITION OF orders_sharded
  FOR VALUES WITH (MODULUS 2, REMAINDER 1)
  SERVER shard1 OPTIONS (table_name 'orders_shard');

-- Route writes automatically by shard key.
INSERT INTO orders_sharded
SELECT id, user_id, status, created_at, ship_country
FROM orders WHERE id <= 200000;

-- Single-shard query: pruned to ONE node. This is the query shape you design for.
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM orders_sharded WHERE user_id = 7 ORDER BY created_at DESC LIMIT 10;
-- Foreign Scan on orders_s1 only. Note "Remote SQL" in VERBOSE output —
-- filter, sort and LIMIT all pushed down to the shard.

-- Cross-shard aggregate: every node participates, coordinator merges.
SET enable_partitionwise_aggregate = on;   -- push the GROUP BY down
SET enable_partitionwise_join = on;
SET max_parallel_workers_per_gather = 2;   -- lets Async Append hit shards in parallel

EXPLAIN (ANALYZE, VERBOSE)
SELECT status, count(*) FROM orders_sharded GROUP BY status;
-- Look for "Async Foreign Scan". Without partitionwise aggregate the
-- coordinator drags every row over the network and aggregates locally.

-- The thing that does not work well:
EXPLAIN (ANALYZE)
SELECT s.user_id, count(*)
FROM orders_sharded s
JOIN users u ON u.id = s.user_id        -- users lives only on the coordinator
GROUP BY s.user_id ORDER BY 2 DESC LIMIT 5;
-- Cross-shard join with a non-colocated table. The usual fix is to
-- REPLICATE small dimension tables to every shard so joins stay local.


-- =====================================================================
-- Choosing a shard key — this decision is effectively permanent
--
--   user_id / tenant_id  ✅ most queries filter by it; one user = one shard
--   order_id             ❌ "all orders for user X" fans out to every shard
--   created_at           ❌ all writes hit today's shard; the rest sit idle
--   country              ❌ TR/US shards are 50x the size of the others
--
-- Test for a good key:
--   1. Can >90% of your queries name the key in the WHERE clause?
--   2. Is the distribution even? Run:
SELECT user_id, count(*) FROM orders
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;   -- if the top user is a huge % -> hot shard
--   3. Do your transactions stay inside one shard? Cross-shard ACID means
--      2PC (PREPARE TRANSACTION), which is slow and needs a resolver.
--
-- Resharding: adding a shard rehashes everything. Mitigate with virtual
-- buckets — hash into 1024 buckets, map buckets to physical nodes, move
-- buckets to rebalance. Same idea as consistent hashing.
--
-- Before hand-rolling this, evaluate Citus. It does distributed planning,
-- reference tables, 2PC and shard rebalancing that this FDW setup does not.
-- =====================================================================
