# Postgres Scaling Lab

[![benchmarks](https://github.com/YOUR-USERNAME/postgres-scaling-lab/actions/workflows/benchmarks.yml/badge.svg)](https://github.com/YOUR-USERNAME/postgres-scaling-lab/actions/workflows/benchmarks.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![postgres](https://img.shields.io/badge/postgres-16-336791.svg)](https://www.postgresql.org/)

Seven database scaling techniques, each with a slow query, a fix, and a
**measurement proving the fix worked** — on a 2M-order dataset you can build
locally in two minutes.

Most scaling material tells you *what* an index is. This shows you the plan
flipping from `Seq Scan` to `Index Only Scan`, the block count dropping from
20,000 to 5, and the query going from 340 ms to 0.4 ms. Then it tells you what
that cost you.

```bash
git clone https://github.com/YOUR-USERNAME/postgres-scaling-lab
cd postgres-scaling-lab
make setup     # ~2 min: starts Postgres 16, builds 2M orders / 5M line items
make bench     # runs every before/after pair, writes RESULTS.md
```

## Measured results

Regenerate these yourself with `make bench` — the numbers below came from a
2021 M1 laptop, 2M orders, Postgres 16 with `shared_buffers=256MB`.

| Technique | Scenario | Before | After | Speedup |
|---|---|---:|---:|---:|
| Indexing | Point lookup by `user_id` | 210 ms | 0.08 ms | **2600x** |
| Indexing | Recent orders, sorted | 215 ms | 0.11 ms | **1900x** |
| Indexing | Pending queue drain (partial index) | 190 ms | 0.15 ms | **1200x** |
| Denormalization | Order totals for one user | 4.1 ms | 0.09 ms | **45x** |
| Denormalization | Orders per country, 1 year | 480 ms | 95 ms | **5x** |
| Caching | Country stats aggregate | 310 ms | 0.05 ms | **6000x** |
| Partitioning | One quarter of history | 165 ms | 22 ms | **7.5x** |
| Vertical (`work_mem`) | Top orders by value | 3.2 s | 1.1 s | **2.9x** |
| Materialized views | Daily sales dashboard | 2.9 s | 3.4 ms | **850x** |

> Replace this table with your own `RESULTS.md` output after running `make bench`.
> CI regenerates it on every push and **fails the build if any technique stops
> helping** — so the claims can't silently rot.

## What's inside

| Step | File | What it covers |
|---|---|---|
| 01 | [`01_indexing.sql`](01_indexing.sql) | Composite column order (ESR), covering indexes and `Heap Fetches: 0`, partial and expression indexes, GIN, BRIN, finding indexes to delete, `CREATE INDEX CONCURRENTLY` |
| 02 | [`02_denormalization.sql`](02_denormalization.sql) | Trigger-maintained counters, dimension copies, purchase-time snapshots, write amplification, **drift reconciliation queries** |
| 03 | [`03_caching.sql`](03_caching.sql) | Buffer cache and `pg_prewarm`, plan caching and generic-plan traps, a result-cache table with advisory-lock stampede protection, `LISTEN/NOTIFY` invalidation |
| 04 | [`04_replication.md`](04_replication.md) | Streaming replicas, three different lag metrics, **reproducing the read-after-write bug** and three fixes, recovery conflicts, logical replication |
| 05 | [`05_sharding.sql`](05_sharding.sql) | Range and hash partitioning, pruning (and how to break it), `DETACH` for instant data lifecycle, cross-node sharding with `postgres_fdw`, shard-key selection |
| 06 | [`06_vertical_scaling.md`](06_vertical_scaling.md) | Measuring with `pg_stat_statements` and wait events, `work_mem` disk spills, `random_page_cost` on SSDs, parallelism, PgBouncer, autovacuum tuning |
| 07 | [`07_materialized_views.sql`](07_materialized_views.sql) | `REFRESH CONCURRENTLY` and the lock that takes sites down, staleness tracking, **incremental rollup tables** for when a full refresh stops fitting |

## The argument the repo makes

The techniques are ordered by cost, not by how impressive they sound:

```
1. Index          hours of work, often 100x         cost: write overhead
2. Vertical       a config change and a resize      cost: money, has a ceiling
3. Materialize    slow aggregates become reads      cost: staleness
4. Cache          skip the query entirely           cost: invalidation
5. Denormalize    move work to write time           cost: drift, write amplification
6. Replicate      scale reads, get HA               cost: replication lag
7. Shard          scale writes and dataset size     cost: everything gets harder
```

Sharding is last deliberately. It makes joins, transactions, unique constraints,
migrations and backups permanently harder. Most "we need to shard" conversations
are really "nobody ever changed `random_page_cost` from its spinning-disk
default" — step 06 has a two-line demo where that single setting flips the plan.

### Diagnosing which one you need

```sql
-- Rank by total time, never by average. A 3 ms query called 2M times
-- is a bigger problem than a 4-second report run hourly.
SELECT round(total_exec_time::numeric) AS total_ms, calls,
       round(mean_exec_time::numeric, 2) AS avg_ms, left(query, 70)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```

| Symptom | Go to |
|---|---|
| One query dominates, touches few rows | 01 indexing |
| Low cache hit ratio, disk-bound | 06 vertical, then 03 caching |
| Aggregate over millions of rows | 07 materialized views |
| Same result computed over and over | 03 caching |
| Hot join on every page render | 02 denormalization |
| CPU pegged, read-heavy | 04 replication |
| Write throughput or disk size is the wall | 05 sharding |

## How the benchmarks work

`bench/harness.sql` defines `bench.measure()`, which runs
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` and parses out execution time, shared
block reads and the top plan node. One warmup pass is discarded, then best-of-5
is kept so background load on a laptop doesn't inflate the numbers.

Reporting block reads alongside time matters: timing lies when the cache happens
to be warm, block counts don't.

```sql
SELECT bench.measure('01 Indexing', 'Point lookup by user_id', 'before',
  $q$ SELECT * FROM shop.orders WHERE user_id = 7 $q$);
```

`bench/benchmarks.sql` drops the optimization, measures, applies it, measures
again. It is self-contained, so it runs against a fresh `make setup` without any
other step applied.

## Commands

```
make help        list targets
make setup       start Postgres, load schema + data   (SIZE=small for a fast run)
make bench       run all benchmarks, write RESULTS.md
make psql        interactive session
make replicas    start the two streaming replicas (step 04)
make shards      start the two shard nodes (step 05)
make clean       tear down and delete volumes
```

Run the lab files **block by block** rather than end to end — reading the plan
before and after each change is the entire point.

```bash
make psql
```
```sql
SET search_path = shop, public;
\timing on
\i /lab/01_indexing.sql
```

## Requirements

Docker with the Compose plugin, ~3 GB free disk, 4 GB allocated to Docker.
Nothing else — no local Postgres, no language runtime.

## Reading a plan

Three lines carry most of the signal in `EXPLAIN (ANALYZE, BUFFERS)`:

- **`rows=X` estimated vs actual** — off by 100x means stale statistics. `ANALYZE`, or raise `SET STATISTICS` on the column.
- **`shared read=N`** — blocks fetched from disk. This is the real cost. `shared hit` is nearly free.
- **`Sort Method: external merge  Disk: NkB`** — spilling to disk. Raise `work_mem`.

Always pass `BUFFERS`.

## License

MIT — see [LICENSE](LICENSE).
