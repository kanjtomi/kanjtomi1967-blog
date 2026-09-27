# S3-backed PersistentVolume — Kubernetes learning lab

Demonstrates mounting an Amazon S3 bucket as a Kubernetes
PersistentVolume, using the official
[AWS Mountpoint for Amazon S3 CSI Driver](https://github.com/awslabs/mountpoint-s3-csi-driver).
Not related to the blog — a standalone learning exercise on the same home
RHEL k8s cluster used for `blog-staging` and `security-lab`, kept in its
own `s3-pv-lab` namespace.

Verified working end-to-end (2026-09-27): PVC `Bound`, demo pod
`1/1 Running`, files written from inside the pod confirmed present in the
S3 bucket via the AWS CLI directly, and confirmed to **survive
`kubectl delete pod` + recreate** — proving the data lives in S3, not in
container-local storage.

## AWS resources (created manually, not Terraform-managed)

Kept out of the main Terraform stack deliberately — same reasoning as
`security-lab`/`site-monitor` being separate from the blog's production
infra: this is a throwaway learning exercise, not something that should
ever get pulled into the blog's real deploy pipeline.

- **S3 bucket**: `kanjtomi1967-k8s-s3-pv-lab` (`ap-northeast-1`), Block
  Public Access enabled
- **IAM user**: `k8s-s3-pv-lab`, with an inline policy scoped to
  *only* this bucket (`s3:ListBucket` on the bucket,
  `s3:GetObject`/`PutObject`/`DeleteObject` on its objects) — deliberately
  not reusing any broader credentials (e.g. the AdministratorAccess user
  flagged by the Prowler audit) for a workload that only ever needs
  access to one bucket

## Cluster-side setup (manual — see below for why)

```bash
# 1. Static credentials for the CSI driver (must exist before the driver starts)
kubectl create secret generic aws-secret \
  --namespace kube-system \
  --from-literal "key_id=<the k8s-s3-pv-lab access key ID>" \
  --from-literal "access_key=<its secret access key>"

# 2. Install the CSI driver (cluster-wide DaemonSet + RBAC)
helm repo add aws-mountpoint-s3-csi-driver https://awslabs.github.io/mountpoint-s3-csi-driver
helm repo update
helm upgrade --install aws-mountpoint-s3-csi-driver aws-mountpoint-s3-csi-driver/aws-mountpoint-s3-csi-driver \
  --namespace kube-system

# 3. Deploy this lab
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/pv-pvc.yaml
kubectl apply -f k8s/demo-pod.yaml
```

**Why steps 1 and 2 weren't run automatically**: both write into
`kube-system` — a Kubernetes Secret containing credentials, and a
cluster-wide DaemonSet — categories of change this session's own safety
tooling treats as requiring a human to actually run the command, same
spirit as never auto-approving a `kubectl apply` that touches shared
cluster state without a person in the loop.

## What was learned: S3 doesn't support append/random-write

The first version of `k8s/demo-pod.yaml` tried to `>>` (append) a
timestamped line to a single `/data/log.txt` every 30s. That worked on
the very first write (creating a new object), but reopening the *same*
object for append after a pod restart failed with
`sh: can't create /data/log.txt: Operation not permitted`. The Mountpoint
S3 CSI driver doesn't support opening an existing S3 object for
random/append writes — S3 objects are fundamentally write-once
(a full PUT), not a POSIX file you can seek into and append to. Fixed by
writing a **new** timestamped file every iteration instead
(`k8s/demo-pod.yaml`'s current form) — a pattern that actually matches
how S3-backed storage behaves, rather than fighting it.

## Checking it

```bash
kubectl -n s3-pv-lab get pvc s3-pv-lab-pvc
kubectl -n s3-pv-lab logs s3-pv-lab-demo

# From wherever the AWS CLI is configured (not necessarily the k8s host):
aws s3 ls s3://kanjtomi1967-k8s-s3-pv-lab/
```

## Teardown

```bash
kubectl delete namespace s3-pv-lab
kubectl delete pv s3-pv-lab-pv   # PV is cluster-scoped, outside the namespace
helm uninstall aws-mountpoint-s3-csi-driver -n kube-system
kubectl delete secret aws-secret -n kube-system
```

Then, in AWS (not automated — infra/credential teardown is the user's
call, same as everywhere else in this repo):

```bash
aws s3 rm s3://kanjtomi1967-k8s-s3-pv-lab --recursive
aws s3api delete-bucket --bucket kanjtomi1967-k8s-s3-pv-lab --region ap-northeast-1
aws iam delete-access-key --user-name k8s-s3-pv-lab --access-key-id <the access key ID>
aws iam delete-user-policy --user-name k8s-s3-pv-lab --policy-name s3-pv-lab-bucket-access
aws iam delete-user --user-name k8s-s3-pv-lab
```
