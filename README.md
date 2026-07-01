# apps_etcd-cluster

etcd cluster offline `.run` installer package for Kubernetes.

This package deploys an etcd cluster as a Kubernetes `StatefulSet` with persistent volumes. It packages the etcd image into the `.run` payload, so the target environment can install without internet access.

## Version

- etcd: `v3.6.10`
- default replicas: `3`
- default service type: `ClusterIP`
- default storage per member: `10Gi`
- default image source: `quay.io/coreos/etcd:v3.6.10`
- default retarget image: `sealos.hub:5000/kube4/etcd/etcd:v3.6.10`

The etcd upstream release page lists `v3.6.10` as the latest release at the time this package was created. The release notes also say etcd uses `gcr.io/etcd-development/etcd` as the primary container registry and `quay.io/coreos/etcd` as secondary. This package uses the secondary registry because it is usually easier to pull from GitHub Actions and offline build environments.

## What this package creates

- Namespace
- Headless service: `etcd-headless`
- Client service: `etcd-client`
- PodDisruptionBudget
- StatefulSet: `etcd`
- PVC per member: `data-etcd-0`, `data-etcd-1`, ...

The in-cluster client endpoint is:

```text
http://etcd-client.<namespace>.svc.cluster.local:2379
```

For the default namespace:

```text
http://etcd-client.etcd-cluster.svc.cluster.local:2379
```

## Build locally

Build host requirements:

- Linux shell
- Docker
- Python 3
- `tar`
- `sha256sum`

No `jq` is required.

Build one architecture:

```bash
bash build.sh --arch amd64
bash build.sh --arch arm64
```

Build both:

```bash
bash build.sh --arch all
```

Artifacts are written to `dist/`:

```text
dist/etcd-cluster-3.6.10-amd64.run
dist/etcd-cluster-3.6.10-amd64.run.sha256
dist/etcd-cluster-3.6.10-arm64.run
dist/etcd-cluster-3.6.10-arm64.run.sha256
```

## Install in an offline environment

Target host requirements:

- `bash`
- common Linux base tools: `awk`, `head`, `wc`, `dd`, `od`, `tail`, `tar`, `sed`
- `docker`, unless `--skip-image-prepare` is used
- `kubectl`
- optional `sha256sum`, only for checking the `.sha256` file before running the installer

The target host does **not** need `jq` or Python.

Install a 3-node etcd cluster:

```bash
sha256sum -c etcd-cluster-3.6.10-amd64.run.sha256
chmod +x etcd-cluster-3.6.10-amd64.run
./etcd-cluster-3.6.10-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'passw0rd' \
  -n etcd-cluster \
  --storage-class nfs-client \
  --storage-size 20Gi \
  -y
```

If the target registry already contains the etcd image:

```bash
./etcd-cluster-3.6.10-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n etcd-cluster \
  -y
```

Install with a NodePort client service:

```bash
./etcd-cluster-3.6.10-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --service-type NodePort \
  --nodeport-client 32379 \
  -n etcd-cluster \
  -y
```

## Status

```bash
./etcd-cluster-3.6.10-amd64.run status -n etcd-cluster
```

Manual checks:

```bash
kubectl get pods,svc,statefulset,pvc -n etcd-cluster
kubectl exec -n etcd-cluster etcd-0 -- \
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --cluster -w table
kubectl exec -n etcd-cluster etcd-0 -- \
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster
```

## Write and read test

```bash
kubectl exec -n etcd-cluster etcd-0 -- \
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 put hello world

kubectl exec -n etcd-cluster etcd-0 -- \
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 get hello
```

## Application connection example

From another Pod in the cluster:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=http://etcd-client.etcd-cluster.svc.cluster.local:2379 \
  endpoint health
```

## Backup snapshot

```bash
kubectl exec -n etcd-cluster etcd-0 -- \
  /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 \
  snapshot save /tmp/etcd-snapshot.db

kubectl cp etcd-cluster/etcd-0:/tmp/etcd-snapshot.db ./etcd-snapshot.db
```

## Uninstall

Safe uninstall keeps PVCs by default:

```bash
./etcd-cluster-3.6.10-amd64.run uninstall -n etcd-cluster -y
```

Delete workload and data PVCs:

```bash
./etcd-cluster-3.6.10-amd64.run uninstall -n etcd-cluster --delete-pvc -y
```

Delete namespace too:

```bash
./etcd-cluster-3.6.10-amd64.run uninstall -n etcd-cluster --delete-pvc --delete-namespace -y
```

## Important production notes

This package is designed as a simple offline-installable etcd cluster for internal Kubernetes networks.

- It does not enable TLS by default.
- It does not enable etcd authentication by default.
- Keep it on a private cluster network unless you add TLS/auth yourself.
- Prefer 3 replicas for normal HA, or 5 for stronger failure tolerance.
- Avoid even replica counts because they do not improve quorum tolerance efficiently.
- Do not casually change `--replicas` after first install. etcd membership changes should be done with explicit member add/remove operations, not only by changing StatefulSet replica count.
- PVC deletion is destructive. Always snapshot before deleting data.

## GitHub Actions

The workflow `.github/workflows/offline-run-packages.yml` builds both `amd64` and `arm64` artifacts on:

- push to `main`
- tag `v*`
- manual `workflow_dispatch`

When a `v*` tag is pushed, the generated `.run` and `.sha256` files are attached to the GitHub Release.
