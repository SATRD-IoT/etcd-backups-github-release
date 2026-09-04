# etcd backups and recovery

Automates daily etcd database snapshots in a Kubernetes control-plane node and uploads each backup set to a GitHub release.

## Backup script

The script creates:

- `<backup>.db.gz`: compressed etcd snapshot
- `<backup>.db.gz.sha256`: checksum for the compressed snapshot
- `<backup>.metadata.txt`: backup metadata
- `<backup>.snapshot-status.txt`: `etcdutl snapshot status` output

If `ENABLE_AGE_ENCRYPTION=true`, the uploaded backup asset is `<backup>.db.gz.age` with its own checksum.

### Required authentication

Do not hardcode GitHub tokens in the script. Export a token with access to the target repository before running it:

```bash
export GH_TOKEN="github_pat_or_fine_grained_token"
```

Alternatively, authenticate the GitHub CLI once:

```bash
gh auth login
```

### Common configuration

All settings can be overridden with environment variables:

```bash
export GITHUB_REPO="your-repo/clusters-backups"
export RELEASE_TAG="your-cluster"
export KEEP_REMOTE="7"
export WORK_DIR="/data/etcd-backup"
```

For encrypted backups, use an age public recipient. It must start with `age1` and it can be generated using the  `age-keygen` command:

```bash
age-keygen -o key.txt
```

With this expected output:

```bash
# created: 2026-09-04T10:50:24Z
# public key: age1...
AGE-SECRET-KEY-1...
```

You have to enable age encryption and configure the age public recipient:

```bash
export ENABLE_AGE_ENCRYPTION="true"
export AGE_RECIPIENT="age1..."
```

Run a dry run to create and validate the local backup without writing to GitHub:

```bash
DRY_RUN=true ./etcd-backups-github-release.sh
```

## Container image

A container image is publicly available at `ghcr.io/satrd-iot/etcd-backups-github-release`.

If you prefer to build the image, the `Dockerfile` packages the backup script and all runtime dependencies:

- `bash`
- `gh`
- `age`
- `etcdctl`
- `etcdutl`
- checksum, compression, TLS, and locking utilities

The bundled etcd tools version defaults to `v3.6.8`. Override it at build time if your cluster needs another compatible etcd client version:

```bash
docker build \
  --build-arg ETCD_VERSION=v3.6.8 \
  -t ghcr.io/your-org/etcd-backups-github-release:latest \
  .
```

Push it to your registry:

```bash
docker push ghcr.io/your-org/etcd-backups-github-release:latest
```

### Multi-arch image

The Dockerfile supports `linux/amd64` and `linux/arm64`. Build and push a multi-arch image with Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg ETCD_VERSION=v3.6.8 \
  -t ghcr.io/your-org/etcd-backups-github-release:latest \
  --push \
  .
```

The selected etcd version must publish both `linux-amd64` and `linux-arm64` release tarballs. The default `v3.6.8` does.

### Local container test

You can test the image entrypoint without touching GitHub by using `DRY_RUN=true`. This still requires access to an etcd endpoint and its TLS certificates:

```bash
docker run --rm \
  --network host \
  -e DRY_RUN=true \
  -e GH_TOKEN='github_pat_or_fine_grained_token' \
  -e GITHUB_REPO='your-repo/clusters-backups' \
  -v /etc/kubernetes/pki/etcd:/etc/kubernetes/pki/etcd:ro \
  ghcr.io/your-org/etcd-backups-github-release:latest
```

## Kubernetes CronJob

The Kubernetes deployment lives in:

- `k8s/etcd-backup-cronjob.yaml`: namespace and CronJob
- `k8s/secret.example.yaml`: example Secret only

Prefer creating the Secret with `kubectl create secret` so credentials do not get written to Git.

### Requirements

The CronJob is designed for a stacked-control-plane Kubernetes node where etcd listens locally on `https://127.0.0.1:2379`.

The manifest:

- schedules the backup daily at `02:00`
- runs only one job at a time with `concurrencyPolicy: Forbid`
- uses `hostNetwork: true` so `127.0.0.1:2379` points to the host etcd process
- mounts `/etc/kubernetes/pki/etcd` from the control-plane node as read-only
- keeps temporary files in an `emptyDir`
- keeps the container root filesystem read-only
- tolerates control-plane/master taints

If your etcd endpoint is not local to the control-plane node, change `ETCD_ENDPOINT` and remove `hostNetwork` if it is not needed.

### Configure the manifest

Review these environment variables in `k8s/etcd-backup-cronjob.yaml`:

```yaml
GITHUB_REPO: your-repo/clusters-backups
RELEASE_TAG: your-cluster
KEEP_REMOTE: "7"
ENABLE_AGE_ENCRYPTION: "false"
ETCD_ENDPOINT: https://127.0.0.1:2379
ETCD_CACERT: /etc/kubernetes/pki/etcd/ca.crt
ETCD_CERT: /etc/kubernetes/pki/etcd/server.crt
ETCD_KEY: /etc/kubernetes/pki/etcd/server.key
```

If your cluster still uses the older master node label instead of the control-plane label, update `nodeSelector`:

```yaml
nodeSelector:
  node-role.kubernetes.io/master: ""
```

### Create the Secret

Create the namespace and GitHub token Secret:

```bash
kubectl create namespace etcd-backups

kubectl -n etcd-backups create secret generic etcd-github-backup \
  --from-literal=GH_TOKEN='github_pat_or_fine_grained_token'
```

If age encryption is enabled, include the public recipient:

```bash
kubectl -n etcd-backups create secret generic etcd-github-backup \
  --from-literal=GH_TOKEN='github_pat_or_fine_grained_token' \
  --from-literal=AGE_RECIPIENT='age1...'
```

Use a fine-grained GitHub token with the minimum permissions needed to create releases and upload/delete release assets in the target repository.

### Deploy

Apply the CronJob manifest:

```bash
kubectl apply -f k8s/etcd-backup-cronjob.yaml
```

Check that it was created:

```bash
kubectl -n etcd-backups get cronjob
```

Create a one-off job from the CronJob to test it immediately:

```bash
kubectl -n etcd-backups create job \
  --from=cronjob/etcd-github-backup \
  etcd-github-backup-manual
```

Watch the job and inspect logs:

```bash
kubectl -n etcd-backups get jobs,pods
kubectl -n etcd-backups logs job/etcd-github-backup-manual
```

Delete the manual test job after it finishes:

```bash
kubectl -n etcd-backups delete job etcd-github-backup-manual
```

### Troubleshooting

If the pod cannot connect to etcd, confirm it landed on a control-plane node and that `hostNetwork: true` is enabled.

If certificate files are missing, verify that `/etc/kubernetes/pki/etcd` exists on the selected node. Some distributions store etcd certificates elsewhere.

If GitHub authentication fails, recreate the Secret and confirm the token has access to the target repository:

```bash
kubectl -n etcd-backups delete secret etcd-github-backup
kubectl -n etcd-backups create secret generic etcd-github-backup \
  --from-literal=GH_TOKEN='github_pat_or_fine_grained_token'
```

If age encryption is enabled and the job fails before upload, confirm `AGE_RECIPIENT` starts with `age1`. Do not put an age private key in the Kubernetes Secret for backup creation.

### Uninstall

Remove the CronJob and Secret:

```bash
kubectl delete -f k8s/etcd-backup-cronjob.yaml
kubectl -n etcd-backups delete secret etcd-github-backup
```

## Restore the etcd DB after a failure

The etcd DB data located at `/var/lib/etcd` can become corrupted after an unexpected power cut. To restore it after a failure, follow these steps.

0. Install `etcdctl` and `etcdutl`.

These binaries can be downloaded from <https://github.com/etcd-io/etcd/releases/>. This repo has been tested with [v3.6.8](https://github.com/etcd-io/etcd/releases/tag/v3.6.8).

Then assign execution permissions and move them to `/usr/local/bin`:

```bash
chmod +x etcdctl etcdutl
mv etcdctl etcdutl /usr/local/bin
```

1. Check `etcd`, `kubelet`, and `containerd` status.

```bash
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health
systemctl status kubelet
systemctl status containerd
```

If `containerd` is down and it cannot be started because its bbolt database is corrupted, remove `/var/lib/containerd`:

```bash
rm -r /var/lib/containerd
```

2. Stop `kubelet`.

```bash
systemctl stop kubelet
```

3. Move the existing etcd data directory aside.

```bash
mv /var/lib/etcd /var/lib/etcd.bak
```

4. Download the selected backup assets from the GitHub release.

For an unencrypted backup, verify and decompress the snapshot:

```bash
sha256sum -c <selected-etcd-snapshot>.db.gz.sha256
gunzip <selected-etcd-snapshot>.db.gz
```

For an age-encrypted backup, decrypt it first:

```bash
age -d -i /path/to/age-private-key.txt -o <selected-etcd-snapshot>.db.gz <selected-etcd-snapshot>.db.gz.age
gunzip <selected-etcd-snapshot>.db.gz
```

5. Check the selected snapshot status.

```bash
ETCDCTL_API=3 etcdutl snapshot status <selected-etcd-snapshot>.db -w table
```

6. Restore the etcd database from the selected snapshot.

```bash
ETCDCTL_API=3 etcdutl snapshot restore <selected-etcd-snapshot>.db --data-dir=/var/lib/etcd
```

7. Check the `etcd` status.

```bash
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health
```

If it is healthy, a message like this will be displayed:

```text
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 7.873523ms
```

If it is unhealthy, restart the machine and check the `etcd` status again.

8. When `etcd` is healthy, start `containerd` if it is stopped, then start `kubelet`.

```bash
systemctl start containerd
systemctl start kubelet
```

9. Remove the old etcd data directory backup after the cluster has been verified.

```bash
rm -r /var/lib/etcd.bak
```
