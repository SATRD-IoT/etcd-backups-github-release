# etcd backups and recovery

Automates the process of creating daily etcd DB backups in a K8s cluster and its further recovery (when needed).

## Restore the etcd DB after a failure

The etcd DB data (localted at */var/lib/etcd*) is prone to be corrupted after a power cut. Therefore, to restore it after a failure follow this steps:

0. First, *etcdctl* and *etcdutl* binaries must be installed.

These binaries can be downloaded at https://github.com/etcd-io/etcd/releases/ . It has been tested with [v3.6.8](https://github.com/etcd-io/etcd/releases/tag/v3.6.8).

Then, assign them with execution permissions and move them to the */usr/local/bin* folder

```bash
chmod +x etcdctl
chmod +x etcdutl
```

```bash
mv etcdctl /usr/local/bin
mv etcdutl /usr/local/bin
```

1. Check *etcd*, *kubelet* and *containerd* (or the used container runtime) status

```bash
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health
```

```bash
systemctl status kubelet
```

```bash
systemctl status containerd
```

If containerd is down and it cannot be started (its bbolt database can also be corrupted), remove the */var/lib/containerd* folder

```bash
rm -r /var/lib/containerd
```

2. Stop the *kubelet*

```bash
systemctl stop kubelet
```

3. Create a backup of the etcd folder (*/var/lib/etcd*)

```bash
mv /var/lib/etcd /var/lib/etcd.bak
```

4. Delete the etcd folder (*/var/lib/etcd*)

```bash
rm -rf /var/lib/etcd/*
```

5. Check the status of a backup created by the CronJob using the *etcdutl snapshot status* command

```bash
ETCDCTL_API=3 etcdutl snapshot status /data/etcd-backup/<selected-etcd-snapshot>.db -w table
```

6. Restore the etcd DB from a backup created by the CronJob using the *etcdutl snapshot restore* command

```bash
ETCDCTL_API=3 etcdutl snapshot restore /data/etcd-backup/<selected-etcd-snapshot>.db --data-dir=/var/lib/etcd
```

7. Check the *etcd* status

```bash
etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health
```

If it's healthy, a message like this will be displayed:

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 7.873523ms
```

If it's unhealthy, restart the machine and check the *etcd* status again. 


8. When *etcd* is healthy, first start *containerd* (only if it's stopped) and then start *kubelet*

```bash
systemctl start containerd
```

```bash
systemctl start kubelet
```

9. Remove the backup of the etcd folder (*/var/lib/etcd.bak*)

```bash
rm -r /var/lib/etcd.bak
```