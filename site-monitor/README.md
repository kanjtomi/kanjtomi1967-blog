# site-monitor on Kubernetes (learning / staging replica)

Uptime/response-time monitoring for the blog's public URLs
(`https://www.kanjtomi1967.net/` and `/search/` by default), running as a
k8s learning/staging replica on the same home RHEL cluster as
`comments-service` (see `lambda-comments/k8s/README.md`). Shares its
namespace (`blog-staging`) but is otherwise independent.

Unlike `comments-service`, this one is **built and deployed automatically
by Jenkins** (see the `Deploy Site Monitor (RHEL k8s)` stage in the root
`Jenkinsfile`) — it needs no secrets (only outbound HTTPS to the blog's own
public URLs) and nothing here touches production traffic, so there was no
reason to keep it manual-only.

## What it does

A single Python (stdlib-only, no dependencies to install) process:

- Every `CHECK_INTERVAL_SECONDS` (default 60), HTTP-GETs each URL in
  `TARGET_URLS` and records success/failure + latency into an in-memory
  ring buffer (`HISTORY_SIZE` entries, default 100)
- Serves the results on port 8080:
  - `/` — a small auto-refreshing HTML dashboard
  - `/status` — JSON snapshot
  - `/metrics` — Prometheus text-format metrics
    (`site_monitor_up`, `site_monitor_response_time_ms`, `site_monitor_uptime_ratio`)
  - `/health` — always 200; this is the container's own liveness/readiness
    signal (process is up), not a proxy for the target site's status —
    check `/status` or `/metrics` for that

## Automatic deploy (Jenkins)

On every `main` build, Jenkins:

1. Copies this directory to the RHEL host over `scp` (SSH key credential
   `rhel-host-ssh-key` in Jenkins)
2. `podman build`s the image there
3. Imports it directly into containerd (`ctr -n k8s.io images import`) —
   same registry-free pattern as `comments-service`
4. `kubectl apply`s `k8s/namespace.yaml`, `configmap.yaml`,
   `deployment.yaml`, `service.yaml`
5. Waits for the rollout to finish

Report-only in spirit like the rest of this pipeline's supplementary
stages: a failure here is wrapped in `catchError` and never blocks the
actual blog deploy (`aws s3 sync` / CloudFront invalidation).

## Manual build/deploy (for local testing on the RHEL host)

```bash
cd site-monitor
podman build -t site-monitor:local .
podman save site-monitor:local -o /tmp/site-monitor.tar
sudo ctr -n k8s.io images import /tmp/site-monitor.tar

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

kubectl -n blog-staging rollout status deployment/site-monitor
```

## Viewing the dashboard

Not exposed outside the cluster by default (`ClusterIP`, same policy as
`comments-service`) — use `kubectl port-forward`:

```bash
kubectl port-forward -n blog-staging svc/site-monitor 8090:80
```

Then open `http://localhost:8090/` in a browser (or `http://localhost:8090/status`,
`/metrics`).

## Configuration

Set in `k8s/configmap.yaml` (`site-monitor-config`):

| Key | Default | Meaning |
|---|---|---|
| `TARGET_URLS` | `https://www.kanjtomi1967.net/,https://www.kanjtomi1967.net/search/` | Comma-separated URLs to check |
| `CHECK_INTERVAL_SECONDS` | `60` | Seconds between check rounds |
| `TIMEOUT_SECONDS` | `10` | Per-request timeout |
| `HISTORY_SIZE` | `100` | Checks retained per URL for the uptime-ratio window |

## Teardown

```bash
kubectl delete deployment site-monitor -n blog-staging
kubectl delete service site-monitor -n blog-staging
kubectl delete configmap site-monitor-config -n blog-staging
```

(Leaves the shared `blog-staging` namespace and `comments-service` alone —
delete the whole namespace only if you're tearing down both replicas.)
