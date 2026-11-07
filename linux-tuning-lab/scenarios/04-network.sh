#!/bin/bash
# ネットワーク: keep-alive の効果と、エフェメラルポート (ip_local_port_range) の枯渇を見る。
#   /scenarios/04-network.sh [リクエスト数=5000] [同時接続=20]
# 1. ab で keep-alive あり / なしを比べる。なしは毎回 3-way handshake するので遅い。
#    (ab の場合は nginx が先に close するので、TIME_WAIT は nginx 側に残る)
# 2. client-close.py は毎回クライアント側から先に close する。TIME_WAIT (約 60 秒) がクライアントに
#    残り、bench Pod の ip_local_port_range をわざと 1000 ポートに絞ってあるので、すぐ
#    "Cannot assign requested address" で失敗する。
# 試すこと:
#   - k8s/bench.yaml の ip_local_port_range を "32768 60999" に広げて apply し直し、2 をもう一度。
#   - 60 秒待ってからもう一度 (TIME_WAIT が消えればまた通る)。
#   - nginx/nginx.conf の worker_processes / worker_connections / keepalive_timeout を変える。
#   - ab -k -n 50000 -c 600 で worker_connections 512 を超える同時接続をかける。
N=${1:-5000}; C=${2:-20}; HOST=web.tuning-lab.svc.cluster.local; URL=http://$HOST/
tw() { ss -tan state time-wait | tail -n +2 | wc -l; }
echo "ip_local_port_range = $(cat /proc/sys/net/ipv4/ip_local_port_range | tr '\t' ' ')   (使えるポート $(awk '{print $2-$1+1}' /proc/sys/net/ipv4/ip_local_port_range) 個)"
summ() { grep -E 'Complete requests|Failed requests|Requests per second|Time per request.*mean\)|apr_socket|Non-2xx' | sed 's/^/  /'; }
echo "--- 1a. ab keep-alive あり: $N リクエスト / 同時 $C"
ab -k -q -n "$N" -c "$C" "$URL" 2>&1 | summ
echo "--- 1b. ab keep-alive なし: $N リクエスト / 同時 $C"
ab -q -r -n "$N" -c "$C" "$URL" 2>&1 | summ
echo "  bench 側の TIME_WAIT: $(tw)  (ab では nginx が先に close するので増えない)"
echo "--- 2. client-close.py (クライアントから先に close): $N リクエスト / 並列 $C"
python3 /scenarios/client-close.py "$HOST" "$N" "$C"
echo "  bench 側の TIME_WAIT: $(tw)  (ポートの数に近ければ枯渇している)"
echo "--- nginx の状態 (空なら、ポート枯渇でこの curl も繋がらなかったということ)"
curl -s --max-time 3 "${URL}stub_status" | sed 's/^/  /'
