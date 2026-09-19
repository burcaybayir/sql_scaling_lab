-- =====================================================================
-- 00_setup.sql — schema + enough data that bad plans actually hurt
-- Run:  psql "postgresql://postgres:lab@localhost:5432/shop" -f 00_setup.sql
-- Takes ~60-120s. Produces ~2M orders and ~5M order_items.
-- =====================================================================

\timing on

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path = shop, public;

-- Deterministic data so your numbers match mine.
SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- Tables: deliberately NO indexes beyond primary keys.
-- Every index in this lab gets added on purpose, in step 01.
-- ---------------------------------------------------------------------

CREATE TABLE users (
  id          bigint PRIMARY KEY,
  email       text        NOT NULL,
  country     char(2)     NOT NULL,
  signup_at   timestamptz NOT NULL,
  is_active   boolean     NOT NULL,
  profile     jsonb       NOT NULL
);

CREATE TABLE products (
  id          bigint PRIMARY KEY,
  sku         text        NOT NULL,
  name        text        NOT NULL,
  category    text        NOT NULL,
  price_cents integer     NOT NULL
);

CREATE TABLE orders (
  id          bigint PRIMARY KEY,
  user_id     bigint      NOT NULL,
  status      text        NOT NULL,   -- 97% 'completed', 2% 'shipped', 1% 'pending'
  created_at  timestamptz NOT NULL,
  ship_country char(2)    NOT NULL
);

CREATE TABLE order_items (
  id          bigint PRIMARY KEY,
  order_id    bigint  NOT NULL,
  product_id  bigint  NOT NULL,
  qty         smallint NOT NULL,
  unit_cents  integer  NOT NULL
);

-- ---------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------

INSERT INTO users (id, email, country, signup_at, is_active, profile)
SELECT
  i,
  'user' || i || '@' || (ARRAY['example.com','mail.test','corp.io'])[1 + (i % 3)],
  (ARRAY['TR','DE','US','GB','FR','NL','ES','IT'])[1 + (i % 8)],
  timestamptz '2021-01-01' + (random() * 1500) * interval '1 day',
  random() < 0.85,
  jsonb_build_object(
    'tier', (ARRAY['free','plus','pro'])[1 + (i % 3)],
    'tags', to_jsonb((ARRAY['newsletter','beta','mobile','web'])[1 + (i % 4):2 + (i % 4)])
  )
FROM generate_series(1, 200000) AS i;

INSERT INTO products (id, sku, name, category, price_cents)
SELECT
  i,
  'SKU-' || lpad(i::text, 8, '0'),
  'Product ' || i,
  (ARRAY['electronics','books','garden','toys','apparel','grocery'])[1 + (i % 6)],
  200 + (random() * 40000)::int
FROM generate_series(1, 20000) AS i;

-- Orders: user_id is Zipf-ish (some whales), created_at spread over 3 years.
INSERT INTO orders (id, user_id, status, created_at, ship_country)
SELECT
  i,
  1 + (power(random(), 2) * 199999)::bigint,
  CASE
    WHEN random() < 0.01  THEN 'pending'
    WHEN random() < 0.03  THEN 'shipped'
    ELSE 'completed'
  END,
  timestamptz '2023-01-01' + (random() * 1000) * interval '1 day',
  (ARRAY['TR','DE','US','GB','FR','NL','ES','IT'])[1 + (i % 8)]
FROM generate_series(1, 2000000) AS i;

-- ~2.5 items per order.
INSERT INTO order_items (id, order_id, product_id, qty, unit_cents)
SELECT
  row_number() OVER (),
  o.id,
  1 + (random() * 19999)::bigint,
  1 + (random() * 3)::smallint,
  200 + (random() * 40000)::int
FROM orders o,
     LATERAL generate_series(1, 1 + (random() * 3)::int) AS g;

-- ---------------------------------------------------------------------
-- Stats. Without ANALYZE the planner is guessing and every EXPLAIN lies.
-- ---------------------------------------------------------------------
ANALYZE users;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;

SELECT
  relname,
  to_char(n_live_tup, '999,999,999') AS rows,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY n_live_tup DESC;

-- Expect roughly:
--   order_items   5,000,000   ~450 MB
--   orders        2,000,000   ~160 MB
--   users           200,000    ~50 MB
--   products         20,000     ~2 MB
