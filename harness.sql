-- =====================================================================
-- bench/harness.sql
-- Measures a query's execution time and buffer usage by parsing
-- EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON). Records best-of-N so a noisy
-- laptop doesn't produce noisy claims.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS bench;

DROP TABLE IF EXISTS bench.results;
CREATE TABLE bench.results (
  technique   text    NOT NULL,   -- '01 Indexing'
  scenario    text    NOT NULL,   -- 'Single user lookup'
  variant     text    NOT NULL,   -- 'before' | 'after'
  exec_ms     numeric NOT NULL,
  shared_read bigint  NOT NULL,   -- blocks from disk
  shared_hit  bigint  NOT NULL,   -- blocks from cache
  plan_node   text    NOT NULL,   -- top node, e.g. 'Seq Scan'
  runs        int     NOT NULL,
  measured_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (technique, scenario, variant)
);

-- ---------------------------------------------------------------------
-- bench.measure(technique, scenario, variant, sql [, runs])
-- One warmup pass (so we compare steady state, not cold cache), then N
-- timed passes. Keeps the fastest — the one least polluted by other load.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bench.measure(
  p_technique text,
  p_scenario  text,
  p_variant   text,
  p_sql       text,
  p_runs      int DEFAULT 5
) RETURNS numeric AS $$
DECLARE
  j          json;
  root       jsonb;
  t          numeric;
  best_t     numeric := NULL;
  best_read  bigint  := 0;
  best_hit   bigint  := 0;
  best_node  text    := '';
BEGIN
  -- Warmup, discarded.
  EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO j;

  FOR i IN 1..p_runs LOOP
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO j;
    root := (j::jsonb) -> 0;
    t    := (root ->> 'Execution Time')::numeric;

    IF best_t IS NULL OR t < best_t THEN
      best_t    := t;
      best_read := coalesce((root -> 'Plan' ->> 'Shared Read Blocks')::bigint, 0);
      best_hit  := coalesce((root -> 'Plan' ->> 'Shared Hit Blocks')::bigint, 0);
      best_node := coalesce(root -> 'Plan' ->> 'Node Type', '?');
      -- Descend one level for wrapper nodes so the label is informative.
      IF best_node IN ('Aggregate','Limit','Sort','Gather','Result') THEN
        best_node := best_node || ' → ' ||
          coalesce(root -> 'Plan' -> 'Plans' -> 0 ->> 'Node Type', '?');
      END IF;
    END IF;
  END LOOP;

  INSERT INTO bench.results
    (technique, scenario, variant, exec_ms, shared_read, shared_hit, plan_node, runs)
  VALUES
    (p_technique, p_scenario, p_variant, best_t, best_read, best_hit, best_node, p_runs)
  ON CONFLICT (technique, scenario, variant) DO UPDATE SET
    exec_ms     = EXCLUDED.exec_ms,
    shared_read = EXCLUDED.shared_read,
    shared_hit  = EXCLUDED.shared_hit,
    plan_node   = EXCLUDED.plan_node,
    runs        = EXCLUDED.runs,
    measured_at = now();

  RAISE NOTICE '% | % | %: %ms (%)',
    p_technique, p_scenario, p_variant, round(best_t, 2), best_node;
  RETURN best_t;
END $$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- bench.report() — emits a GitHub-flavoured markdown table
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bench.report() RETURNS SETOF text AS $$
  WITH paired AS (
    SELECT
      b.technique,
      b.scenario,
      b.exec_ms      AS before_ms,
      a.exec_ms      AS after_ms,
      b.shared_read  AS before_read,
      a.shared_read  AS after_read,
      b.plan_node    AS before_plan,
      a.plan_node    AS after_plan
    FROM bench.results b
    JOIN bench.results a
      ON  a.technique = b.technique
      AND a.scenario  = b.scenario
      AND a.variant   = 'after'
    WHERE b.variant = 'before'
  )
  SELECT line FROM (
    SELECT 0 AS ord, 0 AS sub,
           '| Technique | Scenario | Before | After | Speedup | Blocks read (before → after) |' AS line
    UNION ALL
    SELECT 0, 1, '|---|---|---:|---:|---:|---|'
    UNION ALL
    SELECT 1, row_number() OVER (ORDER BY technique, scenario)::int,
      format('| %s | %s | %s ms | %s ms | **%sx** | %s → %s |',
             technique,
             scenario,
             to_char(before_ms, 'FM999999990.00'),
             to_char(after_ms,  'FM999999990.00'),
             to_char(before_ms / nullif(after_ms, 0), 'FM999990.0'),
             to_char(before_read, 'FM999,999,999'),
             to_char(after_read,  'FM999,999,999'))
    FROM paired
  ) s ORDER BY ord, sub;
$$ LANGUAGE sql;

-- Plan-change detail, useful as a second table in RESULTS.md
CREATE OR REPLACE FUNCTION bench.plan_report() RETURNS SETOF text AS $$
  SELECT line FROM (
    SELECT 0 AS ord, 0 AS sub, '| Scenario | Plan before | Plan after |' AS line
    UNION ALL
    SELECT 0, 1, '|---|---|---|'
    UNION ALL
    SELECT 1, row_number() OVER (ORDER BY b.technique, b.scenario)::int,
      format('| %s | `%s` | `%s` |', b.scenario, b.plan_node, a.plan_node)
    FROM bench.results b
    JOIN bench.results a ON a.technique=b.technique AND a.scenario=b.scenario
                        AND a.variant='after'
    WHERE b.variant='before'
  ) s ORDER BY ord, sub;
$$ LANGUAGE sql;
