-- 03 クエリ検証で使う「遅いクエリ」集。1本ずつ EXPLAIN (ANALYZE, BUFFERS) を付けて実行する。

-- Q1: インデックスが無い列での絞り込み → Seq Scan
SELECT * FROM orders WHERE customer_id = 4242;

-- Q2: 列を関数で包む → インデックスがあっても使えない
SELECT count(*) FROM orders WHERE date_trunc('day', ordered_at) = date_trunc('day', now() - interval '3 days');

-- Q3: 前方一致でない LIKE → B-tree では引けない
SELECT count(*) FROM customers WHERE email LIKE '%999@example.com';

-- Q4: 選択率の違い。cancelled(約1%)と shipped(約89%)で、同じインデックスでもプランが変わる
SELECT count(*), sum(amount) FROM orders WHERE status = 'cancelled';
SELECT count(*), sum(amount) FROM orders WHERE status = 'shipped';

-- Q5: JOIN + 集計 + ソート。work_mem が小さいとディスクに溢れる(Sort Method: external merge)
SELECT c.region, o.status, count(*), sum(o.amount)
FROM orders o JOIN customers c ON c.id = o.customer_id
GROUP BY c.region, o.status
ORDER BY sum(o.amount) DESC;

-- Q6: 深い OFFSET ページング → 読み捨てが増える
SELECT id, ordered_at FROM orders ORDER BY ordered_at DESC OFFSET 500000 LIMIT 20;
