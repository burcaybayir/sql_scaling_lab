# SQL Scaling Lab

A runnable Postgres 16 lab covering the seven techniques, in the order you should
actually reach for them. Every step has a slow "before" query, a fix, and a way to
measure that the fix worked.

The dataset is ~2M orders and ~5M order items — big enough that bad plans hurt,
small enough to build in about two minutes on a laptop.

## Run it

```bash
docker compose up -d pg-primary
docker compose exec pg-primary psql -U postgres -d shop -f /lab/00_setup.sql
```

Then work through the steps. Run them **block by block**, not as whole files —
the point is reading the plan before and after each change.

```bash
PGURL='postgresql://postgres:lab@localhost:5432/shop'
psql "$PGURL" -f 01_indexing.sql
psql "$PGURL" -f 02_denormalization.sql
psql "$PGURL" -f 03_caching.sql
# 04 needs the replicas:  docker compose up -d pg-replica1 pg-replica2
# 05 part 2 needs shards: docker compose up -d pg-shard0 pg-shard1
psql "$PGURL" -f 05_sharding.sql
psql "$PGURL" -f 07_materialized_views.sql
```

| Step | File | Idea |
|---|---|---|
| 01 | `01_indexing.sql` | Touch fewer blocks. Composite order, covering, partial, expression, GIN, BRIN. |
| 02 | `02_denormalization.sql` | Precompute at write time. Trigger counters, dimension copies, snapshots, drift checks. |
| 03 | `03_caching.sql` | Buffer cache, plan cache, result-cache table, `LISTEN/NOTIFY` invalidation, stampede guard. |
| 04 | `04_replication.md` | Streaming replicas, lag metrics, the read-after-write bug and three fixes, logical replication. |
| 05 | `05_sharding.sql` | Partitioning first, then cross-node sharding with `postgres_fdw`. Shard key choice. |
| 06 | `06_vertical_scaling.md` | Measure with `pg_stat_statements`, then `work_mem`, `shared_buffers`, `random_page_cost`, pooling, autovacuum. |
| 07 | `07_materialized_views.sql` | Materialized views, `REFRESH CONCURRENTLY`, and incremental rollup tables. |

## The order matters

Most "we need to shard" conversations are really "we never set
`random_page_cost`". Cheapest first:

```
1. Index          — hours of work, often 100x.        Cost: write overhead.
2. Vertical       — a config change + a resize.       Cost: money, has a ceiling.
7. Materialized   — turn slow aggregates into reads.  Cost: staleness.
3. Cache          — skip the query entirely.          Cost: invalidation.
2. Denormalize    — move work to write time.          Cost: drift, write amp.
4. Replicate      — scale reads, get HA.              Cost: replication lag.
5. Shard          — scale writes and dataset size.    Cost: everything gets harder.
```

Sharding is last for a reason: it makes joins, transactions, unique constraints,
schema migrations and backups all harder, permanently. Earn your way there.

## Which problem do you actually have?

```sql
-- Slow queries? Rank by total time, not average.
SELECT round(total_exec_time::numeric) AS total_ms, calls,
       round(mean_exec_time::numeric,2) AS avg_ms, left(query,70)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```

- One query dominates, hits few rows → **indexing (01)**
- Reads from disk, low cache hit ratio → **vertical (06)**, then **caching (03)**
- Aggregate over millions of rows → **materialized views (07)**
- Same result computed repeatedly → **caching (03)**
- Hot join on every page render → **denormalization (02)**
- CPU pegged, read-heavy → **replication (04)**
- Write throughput or disk size is the wall → **sharding (05)**

## Reading a plan

The three lines that matter in `EXPLAIN (ANALYZE, BUFFERS)`:

- **`rows=X` estimated vs `rows=Y` actual** — off by 100x means stale stats.
  Run `ANALYZE`, or raise `SET STATISTICS` on the column.
- **`shared read=N`** — blocks fetched from disk. This is your real cost.
  `shared hit` is nearly free.
- **`Sort Method: external merge Disk: NkB`** — spilling. Raise `work_mem`.

Use `BUFFERS`, always. Timing lies when the cache is warm; block counts don't.

## Teardown

```bash
docker compose down -v
```
