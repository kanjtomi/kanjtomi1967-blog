-- pgbench 用カスタムスクリプト: キャッシュ済みの 5 万行を主キーで読み、md5 を計算させて CPU だけを燃やす
-- パラレルクエリを切って「1 接続 = 1 コア」にしてある(接続数と CPU 使用率の関係を見やすくするため)
\set a random(1, 1900000)
SET max_parallel_workers_per_gather = 0;
SELECT count(md5(note || id)) FROM orders WHERE id BETWEEN :a AND :a + 50000;
