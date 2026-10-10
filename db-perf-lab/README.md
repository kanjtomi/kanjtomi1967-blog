# DB 性能試験ラボ (RHEL 9 + Kubernetes + PostgreSQL 17)

CPU を使い切る / メモリを使い切る / クエリを検証する、の 3 パターンを安全に再現して観察するための学習環境。
ブログ本体のデプロイ経路とは無関係。

- **perf-db**: PostgreSQL 17。わざと `cpu: 2` / `memory: 1Gi` に絞ってある(ノードは 20 コア / 93GB)
- **perf-bench**: 負荷をかける側(`pgbench` / `psql`)。制限なし
- データ: `customers` 10 万行、`orders` 200 万行(約 250MB)。インデックスは主キーのみ

## セットアップ (RHEL ホスト上で)

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/db-perf-lab
kubectl apply -k .
kubectl -n perf-lab get pods
```

以降のコマンドは短く書くために alias を張っておく:

```bash
alias B='kubectl -n perf-lab exec -it deploy/perf-bench --'   # 負荷側
alias D='kubectl -n perf-lab exec -it deploy/perf-db --'      # DB 側
```

**ターミナルを 2 枚開く。** 1 枚目で常に下の監視を流し、2 枚目で負荷をかける。

```bash
D sh /scenarios/cgroup-watch.sh
```

コンテナ自身の cgroup を直接読んでいる。`throttled_ms` と `anon_MB` の 2 列がこのラボの主役。

`kubectl top`(metrics-server)でも大まかな値は見られるが、15 秒ごとの平均で、スロットリング時間や
anon / file の内訳は出ない。比べてみると「top では CPU 2000m で頭打ちに見えるだけ」なのがわかる:

```bash
watch -n 5 kubectl top pods -n perf-lab
```

ブラウザでグラフとして見るなら Grafana(http://192.168.0.200:30300)の
**Kubernetes / Compute Resources / Pod** で `perf-lab` / `perf-db-...` を選ぶ。CPU・スロットリング・
メモリの推移が残るので、試験後に振り返れる。詳細は [monitoring/README.md](../monitoring/README.md)。

## 1. CPU を使い切る

接続数を 1 → 2 → 4 → 8 と増やして、TPS とレイテンシがどうなるかを見る。

```bash
B pgbench -n -f cpu-burn.sql -c 1 -j 1 -T 20
B pgbench -n -f cpu-burn.sql -c 2 -j 2 -T 20
B pgbench -n -f cpu-burn.sql -c 4 -j 4 -T 20
B pgbench -n -f cpu-burn.sql -c 8 -j 8 -T 20
```

この環境での実測:

| 接続数 | cpu% | throttled_ms/秒 | TPS | 平均レイテンシ |
|---|---|---|---|---|
| 1 | 110 | 0 | 9.4 | 106 ms |
| 2 | 200 | 約 200 | 13.1 | 153 ms |
| 4 | 205 | 約 2,000 | 14.8 | 271 ms |
| 8 | 212 | 約 6,000〜7,500 | 16.3 | 491 ms |

読み取るポイント:

- **cpu% は 200% で頭打ち**(limit 2 コア)。それ以降は接続を増やしても TPS はほぼ増えず、**レイテンシだけが接続数に比例して伸びる**。これが「CPU 飽和」の形。
- **`throttled_ms` が 0 でなくなった時点が飽和点**。1 秒間に 6,000ms = 「合計 6 コア分、使いたいのに止められていた」。
  ノード自体は 20 コアで空いているので、OS の `top` だけ見ていると気づけない(コンテナの limit 起因)。
- 負荷中に `B psql -f observe.sql` を流すと、`pg_stat_activity` で `active` かつ `wait_event` が空の接続が並ぶ
  = ロックや I/O 待ちではなく CPU 待ち。

試してみる: `k8s/postgres.yaml` の `cpu` を `"4"` に変えて `kubectl apply -k .` → 飽和点が 4 接続に動くことを確認。

## 2. メモリを使い切る

`work_mem` は **1 接続・1 ソートごと**の上限。「接続数 × work_mem」が limit を超えると落ちる、というのを体験する。

```bash
# (a) work_mem が小さい → メモリは増えず、ディスク(一時ファイル)に溢れて遅くなる
B pgbench -n -f mem-sort.sql -D wm=4MB -c 4 -j 4 -T 20

# (b) work_mem が大きい・1 接続 → メモリ上でソート。anon が約 200MB 増える。問題なし
B pgbench -n -f mem-sort.sql -D wm=1GB -c 1 -j 1 -T 20

# (c) 同じ設定で 8 接続 → 200MB × 8 > 1Gi → OOM kill
B pgbench -n -f mem-sort.sql -D wm=1GB -c 8 -j 8 -T 20
```

この環境での実測:

| ケース | anon_MB ピーク | 結果 |
|---|---|---|
| (a) 4MB × 4 接続 | 76 | 完走。ただし 1 クエリ 28 秒(一時ファイル + CPU 飽和) |
| (b) 1GB × 1 接続 | 216 | 完走。1 クエリ 11 秒 |
| (c) 1GB × 8 接続 | 711 → 即死 | `perhaps the backend died` で全接続切断、コンテナ再起動 |

(c) の後に確認すること:

```bash
kubectl -n perf-lab get pods                       # RESTARTS が 1 増えている
kubectl -n perf-lab describe pod -l app=perf-db    # Last State: Terminated, Exit Code: 137 (= SIGKILL)
kubectl -n perf-lab logs deploy/perf-db | grep -i recovery   # クラッシュリカバリが走っている
dmesg | grep -i "killed process" | tail            # カーネルの OOM killer の記録
```

読み取るポイント:

- **`mem_MB` は平常時から limit 近く(約 980MB)に張り付いている**が、これは正常。大半は `file_MB`(ページキャッシュ)で、
  足りなくなればカーネルが回収する。危ないのは回収できない **`anon_MB`** の方。
- OOM kill は PostgreSQL のエラーではなく**カーネルによる強制終了**。SQL のエラーメッセージは出ず、接続が突然切れる。
  この環境では Pod の理由欄は `OOMKilled` ではなく `Error` / exit 137 と出たので、`dmesg` まで見て確定させる。
- 復帰後もデータは残る(WAL からのリカバリ)。ただし復帰までの数十秒は接続不可。
- 対策の考え方: `work_mem` は「最悪 接続数 × ソート数 ぶん同時に確保される」前提で決める。(a) の「遅いが落ちない」と
  (c) の「速いが落ちる」の間を探すのが実際のチューニング。

## 3. クエリを検証する

`scenarios/slow-queries.sql` に典型的な遅いクエリを 6 本入れてある。1 本ずつ `EXPLAIN (ANALYZE, BUFFERS)` を付けて読む。

```bash
B psql
```

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 4242;
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 4242;
```

この環境での実測(Q1):

| | プラン | 読んだブロック | 実行時間 |
|---|---|---|---|
| インデックス無し | Parallel Seq Scan(200 万行読んで 20 行残す) | 26,667 | 163 ms |
| インデックス有り | Bitmap Index Scan | 26 | 0.125 ms |

EXPLAIN で見る場所:

| 見る場所 | 意味 |
|---|---|
| `Seq Scan` + `Rows Removed by Filter` が大きい | 読み捨てが多い → インデックス候補 |
| `rows=`(見積り)と `actual rows=` の乖離 | 統計が古い / 偏りを掴めていない → `ANALYZE` |
| `Buffers: shared read=` | キャッシュに無くディスクから読んだ量 |
| `Sort Method: external merge  Disk:` | `work_mem` 不足でディスクソート(Q6 で 4MB のとき発生) |
| `loops=` が大きい Nested Loop | 内側が繰り返し実行されている |

各クエリのお題:

- **Q2**: `ordered_at` にインデックスを張っても使われない → 条件を `ordered_at >= ... AND ordered_at < ...` に書き換える
- **Q3**: `LIKE '%...'` は B-tree では引けない → `pg_trgm` + GIN を試す
- **Q4**: `status` にインデックスを張り、`cancelled`(1%)と `shipped`(89%)でプランが変わるのを見る
- **Q5**: `SET work_mem` を 4MB / 64MB で変えて Hash / Sort の挙動を比べる
- **Q6**: `OFFSET` をやめてキーセットページング(`WHERE ordered_at < :last ORDER BY ... LIMIT 20`)に書き換える

全体を俯瞰するとき(どのクエリが一番時間を食っているか、Seq Scan が多いテーブルはどれか):

```bash
B psql -f observe.sql
B psql -c "SELECT pg_stat_statements_reset()"   # 計測をやり直す前にリセット
```

## 片付け

```bash
kubectl delete namespace perf-lab
```

DB を初期状態に戻すだけなら(張ったインデックスも消える):

```bash
kubectl -n perf-lab delete pod -l app=perf-db
```
