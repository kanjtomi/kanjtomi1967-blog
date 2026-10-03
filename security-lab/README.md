# DVWA (Damn Vulnerable Web Application) — security testing lab

A deliberately vulnerable PHP/MariaDB web app (SQLi, XSS, CSRF, command
injection, file upload, and more — one page per vulnerability class),
used to practice web application security testing. Not related to the
blog — this is a standalone security lab on the same home RHEL k8s
cluster used for the `blog-staging` learning replicas
(`comments-service`, `site-monitor`), kept in its own `security-lab`
namespace so it can be torn down independently.

Upstream project: [digininja/DVWA](https://github.com/digininja/DVWA).
Two pods: `dvwa` (built from DVWA's own upstream Dockerfile, `php:8-apache`
base) and `mariadb` (official `docker.io/library/mariadb` image), talking
over the in-cluster `mariadb` Service. Verified working and stable
(2026-09-23): both pods `1/1 Running`, 0 restarts, DVWA's app container at
~19MB RSS and MariaDB at ~100MB RSS after 30s, `/login.php` returns HTTP
200 via `kubectl port-forward`.

## Why two pods, and why a custom-built DVWA image

The two popular pre-built all-in-one DVWA Docker Hub images —
`vulnerables/web-dvwa` and `citizenstig/dvwa` — both **OOMKilled within
seconds of starting mysqld on this cluster, regardless of memory limit**
(tried 512Mi through 20Gi; `memory.current` on the container's cgroup hit
over 17GB before being killed, even though `SHOW VARIABLES` correctly
reported a 128MB `innodb_buffer_pool_size`). Root-caused by process of
elimination — buffer pool size/instances, `/proc/meminfo` visibility,
ulimits, CPU-quota/glibc-arena interaction, and THP were all ruled out one
by one, then confirmed decisively by running the plain upstream
`mariadb:10.5` image standalone under this exact same k8s/containerd
setup: completely stable at ~100MB. Both broken images are ~2016-2018-era
builds; their bundled MariaDB binaries are almost certainly incompatible
with this host's modern kernel (RHEL 9, 5.14) in some way that was never
tracked down further than that. Splitting the DB into its own pod using
the trusted, actively-maintained upstream MariaDB image — and building
the DVWA app itself from its own upstream Dockerfile rather than trusting
a stale third-party bundle — sidesteps the whole problem.

## ⚠️ Security warning

**This application is intentionally full of unpatched, exploitable
vulnerabilities. Never expose it outside the cluster.** Both
`k8s/dvwa-service.yaml` and `k8s/mariadb-service.yaml` are `ClusterIP` on
purpose — access DVWA only via `kubectl port-forward` from a trusted
machine, and only while you're actively using it. Do not change either
Service type to `NodePort`/`LoadBalancer`, and do not open a firewall
port to them.

## Manual deploy (not wired into Jenkins — see below for why)

```bash
# 1. Database secret (not committed — pick your own values)
kubectl create secret generic dvwa-db-secret -n security-lab \
  --from-literal=MARIADB_ROOT_PASSWORD=<pick something> \
  --from-literal=MARIADB_PASSWORD=<pick something>

# 2. MariaDB (official upstream image, no build needed)
podman pull docker.io/library/mariadb:10.5
podman tag docker.io/library/mariadb:10.5 localhost/mariadb-dvwa:local
podman save localhost/mariadb-dvwa:local -o /tmp/mariadb-dvwa.tar
sudo ctr -n k8s.io images import /tmp/mariadb-dvwa.tar
rm -f /tmp/mariadb-dvwa.tar

# 3. DVWA app (built from DVWA's own upstream Dockerfile)
git clone --depth 1 https://github.com/digininja/DVWA.git /tmp/DVWA
cd /tmp/DVWA
podman pull docker.io/library/composer:latest   # referenced by DVWA's multi-stage Dockerfile
podman build -t dvwa-app:local .
podman save dvwa-app:local -o /tmp/dvwa-app.tar
sudo ctr -n k8s.io images import /tmp/dvwa-app.tar
rm -f /tmp/dvwa-app.tar

# 4. Deploy both
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/mariadb-deployment.yaml -f k8s/mariadb-service.yaml
kubectl apply -f k8s/dvwa-deployment.yaml -f k8s/dvwa-service.yaml

kubectl -n security-lab rollout status deployment/mariadb
kubectl -n security-lab rollout status deployment/dvwa
```

Same registry-free podman-build/pull → `ctr` import pattern as
`comments-service` and `site-monitor` — nothing here needs an external
registry the cluster can push to.

**Why this isn't automated in Jenkins**, unlike `site-monitor`: the DVWA
image build step lives in an external repo (digininja/DVWA), not this
one, so there's nothing here for a `main` push to trigger a rebuild of —
and it's a deliberately-vulnerable tool that should only run when someone
is actively using it for testing, not something that belongs being kept
continuously running/redeployed by CI.

## Using it

```bash
kubectl port-forward -n security-lab svc/dvwa 8888:80
```

Open `http://localhost:8888/` in a browser. First-time setup: go to
`/setup.php` and click "Create / Reset Database" (the `dvwa` database
starts empty). Default login is `admin` / `password`. The DVWA UI has a
security-level selector (low/medium/high/impossible) per vulnerability
class — start at "low" to see each vulnerability work, then raise the
level to see the same attack get progressively harder.

## Teardown

```bash
kubectl delete namespace security-lab
```

Removes everything in one shot — nothing here persists data anyone
would want to keep (it's a deliberately-broken practice app, not a real
system).
