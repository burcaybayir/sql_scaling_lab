# 04 — Replication

Replication scales **reads** and gives you failover. It does nothing for write
throughput, and it introduces a new class of bug: reading your own write and not
seeing it.

`docker-compose.yml` already builds a primary and two streaming replicas via
`pg_basebackup -R -C`. Start them:

```bash
docker compose up -d pg-primary pg-replica1 pg-replica2
docker compose logs -f pg-replica1   # wait for "database system is ready to accept read-only connections"
```

Connections used below:

```bash
PRIMARY='postgresql://postgres:lab@localhost:5432/shop'
REPLICA1='postgresql://postgres:lab@localhost:5433/shop'
REPLICA2='postgresql://postgres:lab@localhost:5434/shop'
```

---

## A. Confirm the topology

On the primary:

```sql
SELECT pg_is_in_recovery();          -- f

SELECT
  application_name,
  client_addr,
  state,                             -- streaming
  sync_state,                        -- async
  sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;

SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

On a replica:

```sql
SELECT pg_is_in_recovery();          -- t
INSERT INTO shop.orders VALUES (1,1,'x',now(),'TR');
-- ERROR: cannot execute INSERT in a read-only transaction
```

That error is the whole contract. Your app must know which connection it holds.

---

## B. Measure lag properly

Three different numbers, and people mix them up constantly:

```sql
-- On the PRIMARY: byte lag per replica, broken down by stage
SELECT
  application_name,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS pending_send,
  pg_size_pretty(pg_wal_lsn_diff(sent_lsn,  flush_lsn))             AS pending_flush,
  pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn))            AS pending_replay,
  write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
```

```sql
-- On a REPLICA: time lag. Careful — this reads 0 when the primary is idle,
-- because there is nothing new to replay. Byte lag is the honest metric.
SELECT
  CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()
       THEN 0
       ELSE EXTRACT(epoch FROM now() - pg_last_xact_replay_timestamp())
  END AS lag_seconds;
```

Generate load on the primary and watch lag move:

```bash
docker exec -it pg-primary psql -U postgres -d shop -c \
  "INSERT INTO shop.orders (id,user_id,status,created_at,ship_country)
   SELECT 3000000+i, 1+(i%200000), 'completed', now(), 'TR'
   FROM generate_series(1,500000) i;"
```

---

## C. Reproduce the read-after-write bug

This is the failure every read-replica rollout hits in week one.

```bash
# Write on primary, immediately read on replica
psql "$PRIMARY" -c "INSERT INTO shop.orders VALUES (98000001, 7, 'pending', now(), 'TR', 0, 0, 'TR');" \
  && psql "$REPLICA1" -c "SELECT count(*) FROM shop.orders WHERE id = 98000001;"
```

Under load you will sometimes get `0`. The user submits a form, gets redirected,
and their own record isn't there.

### Fix 1 — LSN pinning (precise, no throughput cost on the primary)

```sql
-- On the primary, after the write, in the same session:
SELECT pg_current_wal_insert_lsn();   -- e.g. 0/3A2F118  -> stash in the user session
```

```sql
-- On the replica, before the read:
SELECT pg_last_wal_replay_lsn() >= '0/3A2F118'::pg_lsn AS is_caught_up;
-- false -> route this read to the primary instead (or wait ~50ms and retry)
```

### Fix 2 — synchronous replication (simple, costs write latency)

On the primary:

```sql
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (walreceiver)';
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
SELECT pg_reload_conf();
```

`remote_apply` means COMMIT does not return until a replica has *replayed* the
change — so any replica read after that commit is correct. You just added a
network round trip to every write, and if the sync replica dies, **writes
block**. Always configure `ANY 1 (...)` over 2+ replicas, never a single named one.

### Fix 3 — route by intent (what most apps actually do)

Send anything inside "the user just acted" (typically a few seconds, sticky per
session) to the primary; everything else to a replica. Cheap and good enough.

---

## D. Long queries on replicas cancel themselves

```sql
-- On replica1, start a slow analytical query:
SELECT count(*) FROM shop.order_items oi JOIN shop.orders o ON o.id = oi.order_id;
```

```bash
# Meanwhile on the primary:
psql "$PRIMARY" -c "DELETE FROM shop.orders WHERE id = 98000001; VACUUM shop.orders;"
```

The replica may kill the query:
`ERROR: canceling statement due to conflict with recovery`

The replica must apply the primary's VACUUM, which removes rows your query still
needs. Two knobs, pick your poison:

| Setting | Effect | Cost |
|---|---|---|
| `max_standby_streaming_delay = 30s` | pause replay up to 30s to let queries finish | lag spikes |
| `hot_standby_feedback = on` | replica tells primary "don't vacuum these rows yet" | **bloat on the primary** |

Compose already sets `hot_standby_feedback=on`. For an analytics replica that's
right. For an HA standby it isn't — you don't want your reporting queries
bloating production.

---

## E. Logical replication — replicate a subset, cross version

Physical replication copies the whole cluster, byte for byte. Logical replication
copies chosen tables, and the target is writable.

On the primary:

```sql
ALTER SYSTEM SET wal_level = 'logical';  -- requires restart
-- docker compose restart pg-primary

CREATE PUBLICATION analytics_pub FOR TABLE shop.orders, shop.order_items;
```

On pg-shard0 (used here as an independent target):

```sql
CREATE SCHEMA shop;
-- create matching table DDL first — logical replication does NOT copy schema
CREATE TABLE shop.orders (LIKE ... );

CREATE SUBSCRIPTION analytics_sub
  CONNECTION 'host=pg-primary dbname=shop user=postgres password=lab'
  PUBLICATION analytics_pub;

SELECT * FROM pg_stat_subscription;
```

Use it for: major-version upgrades with near-zero downtime, feeding a warehouse,
splitting a monolith DB per service. Watch out: it does not replicate DDL,
sequences, or `TRUNCATE` by default, and replica identity must be set for
UPDATE/DELETE on tables without a PK.

---

## F. What replication does not fix

- **Write throughput.** Every replica applies 100% of the primary's writes. Ten
  replicas = ten machines each doing all the write work. → step 05.
- **Dataset size.** Every replica stores the full dataset. → step 05.
- **Connection count.** Each replica has its own `max_connections`; put PgBouncer
  in front of each. → step 06.
