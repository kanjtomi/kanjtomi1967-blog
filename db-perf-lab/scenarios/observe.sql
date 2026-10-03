-- 負荷中に別ターミナルから流す観測クエリ: psql -f observe.sql

\echo '== 接続の状態と待ち理由 (wait_event が NULL で active = CPU を使っている) =='
SELECT state, wait_event_type, wait_event, count(*)
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3 ORDER BY 4 DESC;

\echo '== 重いクエリ TOP5 (合計時間順) =='
SELECT calls,
       round(total_exec_time::numeric, 0) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       shared_blks_hit, shared_blks_read, temp_blks_written,
       left(query, 70) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;

\echo '== 一時ファイル(= work_mem 不足でディスクに溢れた量)とキャッシュヒット率 =='
SELECT temp_files, pg_size_pretty(temp_bytes) AS temp_bytes,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database WHERE datname = current_database();

\echo '== テーブルごとの Seq Scan / Index Scan 回数 =='
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup
FROM pg_stat_user_tables ORDER BY seq_tup_read DESC;
