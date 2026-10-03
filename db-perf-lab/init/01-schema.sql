CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- クエリ検証用のデータ。わざとインデックスは主キーだけにしてある(03 で自分で張る)
CREATE TABLE customers (
    id         bigint PRIMARY KEY,
    email      text NOT NULL,
    region     text NOT NULL,
    created_at timestamptz NOT NULL
);

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    status      text NOT NULL,
    amount      numeric(10,2) NOT NULL,
    ordered_at  timestamptz NOT NULL,
    note        text
);

INSERT INTO customers
SELECT g,
       'user' || g || '@example.com',
       (ARRAY['tokyo','osaka','nagoya','fukuoka','sapporo'])[1 + g % 5],
       now() - (g % 1000) * interval '1 day'
FROM generate_series(1, 100000) g;

-- 200万行。status は偏らせる(cancelled は約1%) → 選択率とインデックスの効き方を見るため
INSERT INTO orders
SELECT g,
       1 + (g::bigint * 7919) % 100000,
       CASE WHEN g % 100 = 0 THEN 'cancelled'
            WHEN g % 10  = 0 THEN 'pending'
            ELSE 'shipped' END,
       (g % 50000) / 100.0,
       now() - (g % 730) * interval '1 day' - (g % 86400) * interval '1 second',
       md5(g::text)
FROM generate_series(1, 2000000) g;

ANALYZE;
