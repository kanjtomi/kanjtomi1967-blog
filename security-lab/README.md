# DVWA (Damn Vulnerable Web Application) — security testing lab

A deliberately vulnerable PHP/MariaDB web app (SQLi, XSS, CSRF, command
injection, file upload, and more — one page per vulnerability class),
used to practice web application security testing. Not related to the
blog — this is a standalone security lab on the same home RHEL k8s
cluster used for the `blog-staging` learning replicas
(`comments-service`, `site-monitor`), kept in its own `security-lab`
namespace so it can be torn down independently.

Upstream project: [digininja/DVWA](https://github.com/digininja/DVWA).
Image used: `docker.io/vulnerables/web-dvwa` (Apache + MariaDB + PHP all
bundled in one container — no separate database pod needed).

## ⚠️ Status: not currently running (unresolved OOM issue)

The image was pulled and deployed once (2026-09-23), but the `dvwa`
container OOMKills within seconds of starting mysqld — tried 512Mi, 2Gi,
and 4Gi memory limits, all failed the same way, on a host with 93GB free.
Suspect the bundled MariaDB doesn't respect cgroup memory limits when
auto-sizing its InnoDB buffer pool. See the comment at the top of
`k8s/deployment.yaml` for the working theory and the next debugging step.
`replicas` is left at `0` in the checked-in manifest so `kubectl apply`
doesn't just start a crash loop — this needs someone to actually debug
the buffer pool sizing before it's usable.

## ⚠️ Security warning

**This application is intentionally full of unpatched, exploitable
vulnerabilities. Never expose it outside the cluster.** `k8s/service.yaml`
is `ClusterIP` on purpose — access it only via `kubectl port-forward`
from a trusted machine, and only while you're actively using it. Do not
change the Service type to `NodePort`/`LoadBalancer`, and do not open a
firewall port to it.

## Manual deploy (not wired into Jenkins — see below for why)

```bash
podman pull docker.io/vulnerables/web-dvwa:latest
podman tag docker.io/vulnerables/web-dvwa:latest localhost/dvwa:local
podman save localhost/dvwa:local -o /tmp/dvwa.tar
sudo ctr -n k8s.io images import /tmp/dvwa.tar
rm -f /tmp/dvwa.tar

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

kubectl -n security-lab rollout status deployment/dvwa
```

Same registry-free podman-build/pull → `ctr` import pattern as
`comments-service` and `site-monitor` — nothing here needs an external
registry the cluster can push to.

**Why this isn't automated in Jenkins**, unlike `site-monitor`: it's a
third-party image with nothing in this repo to build or redeploy on a
`main` push, and it's a deliberately-vulnerable tool that should only run
when someone is actively using it for testing — not something that
belongs being kept continuously running/redeployed by CI.

## Using it

```bash
kubectl port-forward -n security-lab svc/dvwa 8888:80
```

Open `http://localhost:8888/` in a browser. First-time setup: go to
`/setup.php` and click "Create / Reset Database" (the bundled MariaDB
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
