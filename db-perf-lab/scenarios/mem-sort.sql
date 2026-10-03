-- pgbench 用カスタムスクリプト: 1 接続あたり work_mem を上限にメモリ上でソートする
-- 使い方: pgbench -n -f mem-sort.sql -D wm=64MB -c 8 -T 30
SET work_mem = ':wm';
SELECT count(*) FROM (SELECT g, md5(g::text) AS h FROM generate_series(1, 1500000) g ORDER BY h) s;
