# 06 — Vertical scaling

Bigger machine, better config. Boring, unglamorous, and usually the highest
return per hour of effort — right up until it isn't.

Every experiment below is **measure → change one thing → measure again**. The
compose file deliberately starts Postgres with small settings so you can see the
difference.

---

## A. Measure before touching anything

```sql
SELECT pg_stat_statements_reset();
-- ...run your workload / the queries from steps 01-03...

SELECT
  round(total_exec_time::numeric)      AS total_ms,
  calls,
  round(mean_exec_time::numeric, 2)    AS avg_ms,
  round(100.0 * shared_blks_hit /
        nullif(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
  left(query, 80)                      AS query
FROM pg_stat_statements
WHERE query NOT ILIKE '%pg_stat%'
ORDER BY total_exec_time DESC
LIMIT 10;
```

Rank by `total_exec_time`, never by `avg_ms`. A 3 ms query called 2 million times
is a bigger problem than a 4-second report run once an hour.

What is the server actually waiting on right now:

```sql
SELECT wait_event_type, wait_event, count(*), left(query, 60)
FROM pg_stat_activity
WHERE state = 'active' AND pid <> pg_backend_pid()
GROUP BY 1,2,4 ORDER BY 3 DESC;
```

- `IO / DataFileRead` → more RAM, or fewer blocks (step 01)
- `LWLock / BufferMapping` → `shared_buffers` contention
- `Lock / transactionid` → row contention, not a hardware problem
- `Client / ClientRead` → idle-in-transaction; fix the app, not the server

---

## B. `work_mem` — the most visible knob

This one you can see in a plan. Sorting 5M rows with 4 MB of working memory:

```sql
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, sum(qty * unit_cents) AS total
FROM shop.order_items
GROUP BY order_id
ORDER BY total DESC
LIMIT 100;
```

Look for:

```
Sort Method: external merge  Disk: 96000kB
```

It spilled to disk. Now:

```sql
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, sum(qty * unit_cents) AS total
FROM shop.order_items
GROUP BY order_id
ORDER BY total DESC
LIMIT 100;
```

```
Sort Method: quicksort  Memory: 204800kB
```

Typically 3–10x faster on this query.

**The trap:** `work_mem` is per *sort/hash node*, per *parallel worker*, per
*connection*. One query with 4 sorts and 4 workers can use `16 × work_mem`. At
200 connections, `256MB` is a theoretical 50+ GB. Set it low globally and raise
it per session for known-heavy reports:

```sql
ALTER SYSTEM SET work_mem = '16MB';                  -- global floor
ALTER ROLE analytics_user SET work_mem = '512MB';    -- report role only
-- or: SET LOCAL work_mem = '512MB'; inside one transaction
```

---

## C. `shared_buffers` and `effective_cache_size`

```sql
SHOW shared_buffers;          -- 256MB in this lab; dataset is ~700MB
```

```sql
SELECT
  pg_size_pretty(sum(pg_total_relation_size(relid))) AS dataset,
  pg_size_pretty(
    (SELECT setting::bigint * 8192 FROM pg_settings WHERE name='shared_buffers')
  ) AS buffers
FROM pg_stat_user_tables WHERE schemaname='shop';
```

Dataset larger than buffers → you're reading from disk. Raise it:

```bash
docker compose down pg-primary
# edit docker-compose.yml: -c shared_buffers=1GB -c effective_cache_size=3GB
docker compose up -d pg-primary
```

Then re-run the queries from step 01 and compare `shared read` vs `shared hit` in
`EXPLAIN (ANALYZE, BUFFERS)`.

Starting points on a dedicated box:

| Setting | Value | Why |
|---|---|---|
| `shared_buffers` | 25% of RAM | more rarely helps; the OS page cache also caches |
| `effective_cache_size` | 50–75% of RAM | planner hint only, allocates nothing |
| `work_mem` | RAM ÷ (4 × max_connections) | per-node, see the trap above |
| `maintenance_work_mem` | 1–2 GB | speeds up CREATE INDEX and VACUUM a lot |
| `max_wal_size` | 8–16 GB | fewer checkpoints on write-heavy loads |
| `random_page_cost` | `1.1` on SSD/NVMe | default `4.0` assumes spinning rust |
| `effective_io_concurrency` | `200` on NVMe | enables aggressive bitmap prefetch |

`random_page_cost` is the single most commonly wrong setting on modern hardware.
At `4.0` the planner systematically prefers seq scans over index scans. Try it:

```sql
SET random_page_cost = 4.0;
EXPLAIN SELECT * FROM shop.orders WHERE user_id BETWEEN 100 AND 900;
SET random_page_cost = 1.1;
EXPLAIN SELECT * FROM shop.orders WHERE user_id BETWEEN 100 AND 900;
```

The plan flips.

---

## D. Parallelism — using the cores you paid for

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE) SELECT count(*) FROM shop.order_items WHERE unit_cents > 20000;

SET max_parallel_workers_per_gather = 4;
EXPLAIN (ANALYZE) SELECT count(*) FROM shop.order_items WHERE unit_cents > 20000;
```

You should see `Gather → Parallel Seq Scan` and a near-linear speedup on the scan.

Parallelism only kicks in above a size threshold, so on smaller tables nothing
happens until you lower it:

```sql
SET min_parallel_table_scan_size = '8MB';
SET parallel_setup_cost = 100;      -- default 1000 discourages short parallel queries
```

It does **not** help short OLTP queries — worker startup costs more than the
query. It's an analytics knob.

---

## E. Connections: where vertical scaling actually dies

Each Postgres connection is an OS process with its own memory. Past a few hundred
you spend more time context-switching than working.

```sql
SELECT count(*), state FROM pg_stat_activity GROUP BY state;
SHOW max_connections;
```

Raising `max_connections` to 2000 makes things **worse**. The fix is a pooler:

```yaml
  pgbouncer:
    image: edoburu/pgbouncer
    environment:
      DB_HOST: pg-primary
      DB_USER: postgres
      DB_PASSWORD: lab
      POOL_MODE: transaction     # 5000 client conns -> 50 server conns
      MAX_CLIENT_CONN: 5000
      DEFAULT_POOL_SIZE: 50
    ports: ["6432:5432"]
```

`transaction` pooling is the useful mode, and it breaks things that assume a
persistent session: session-level `SET`, `LISTEN/NOTIFY`, advisory session locks,
`WITH HOLD` cursors, and server-side prepared statements on older versions. Know
this before switching, or step 03's NOTIFY example will quietly stop working.

Rule of thumb for pool size: `cores × 2 + effective_spindles`. Usually far smaller
than people expect.

---

## F. Autovacuum — the silent vertical-scaling killer

A table that bloats keeps growing until it no longer fits in RAM, and then the
hardware you bought stops mattering.

```sql
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/nullif(n_live_tup+n_dead_tup,0), 1) AS dead_pct,
       last_autovacuum, autovacuum_count
FROM pg_stat_user_tables
WHERE schemaname='shop'
ORDER BY n_dead_tup DESC;
```

Default `autovacuum_vacuum_scale_factor = 0.2` means a 100M-row table waits for
20M dead rows before vacuuming. On big hot tables, override per table:

```sql
ALTER TABLE shop.orders SET (
  autovacuum_vacuum_scale_factor  = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit    = 2000
);
```

---

## G. The ceiling

Vertical scaling ends when:

- the biggest instance your cloud sells is still not enough
- price goes superlinear (the top instance costs 4x the one below for 2x specs)
- you need HA anyway, so you're buying a replica regardless → step 04
- a single write stream saturates one disk's WAL throughput → step 05

Until one of those is true, a config change and an instance resize beat a
distributed rewrite every single time.
