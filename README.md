# CNPG Chaos Test

Automated failover and replication testing for a [CloudNativePG](https://cloudnative-pg.io/) PostgreSQL cluster running on Kubernetes (Minikube).

---

## What it does

Runs an end-to-end chaos test against a CNPG cluster:

1. Writes a canary row to the primary pod
2. Verifies the row has replicated to all replica pods
3. Hard-kills the primary pod (`--grace-period=0 --force`)
4. Waits for CNPG to elect a new primary and measures the failover time
5. Confirms the canary row is intact on the new primary (data integrity check)
6. Reports the final cluster topology

Each run gets a unique `run_id` (e.g. `chaos-6878`) so you can correlate writes across runs in the `chaos_test` table.

---

## Cluster setup

The script was built for this CNPG cluster definition:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-pg-cluster
spec:
  instances: 3        # 1 primary + 2 replicas
  imageName: ghcr.io/cloudnative-pg/postgresql:16.2
  storage:
    size: 1Gi
    storageClass: standard
  bootstrap:
    initdb:
      database: app_db
      owner: app_user
  monitoring:
    enablePodMonitor: true
```

Install the CNPG operator before applying:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml
```

---

## Prerequisites

- `kubectl` configured and pointing at your cluster
- CNPG operator installed
- Cluster secret `my-pg-cluster-app` present (created automatically by CNPG)

---

## Usage

```bash
chmod +x cnpg-chaos-test.sh

# Full test — write, replicate, kill, failover, integrity check
./cnpg-chaos-test.sh

# Only test replication (no kill)
./cnpg-chaos-test.sh --skip-kill

# Only test failover (no write/replication check)
./cnpg-chaos-test.sh --skip-write

# Custom cluster or namespace
CLUSTER=my-pg-cluster NAMESPACE=chatops ./cnpg-chaos-test.sh
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--cluster` | `my-pg-cluster` | CNPG cluster name |
| `--namespace` | `default` | Kubernetes namespace |
| `--skip-write` | off | Skip write + replication steps |
| `--skip-kill` | off | Skip kill + failover steps |

---

## How primary detection works

CNPG automatically labels pods with `cnpg.io/instanceRole=primary` or `replica`. The script uses these labels to find the current primary without hardcoding any pod names:

```bash
kubectl get pod \
  -l "cnpg.io/cluster=my-pg-cluster,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}'
```

This means the script works correctly even after a failover has already happened and a different pod is now primary.

---

## Password handling

CNPG uses `scram-sha-256` auth even for `127.0.0.1` connections inside the pod. The script fetches the password automatically from the cluster secret:

```bash
DB_PASS=$(kubectl get secret my-pg-cluster-app \
  -o jsonpath='{.data.password}' | base64 --decode)
```

It is passed into the pod via `env PGPASSWORD=` on each `kubectl exec` call — no `.pgpass` file or manual export needed.

---

## Example output

```
CNPG Chaos Test — chaos-6878
  cluster: my-pg-cluster  namespace: default
  →  Primary: my-pg-cluster-2
  →  Replicas: my-pg-cluster-1 my-pg-cluster-3

Step 1 — Ensure chaos_test table exists
  ✓  Table ready

Step 2 — Write test row to primary (my-pg-cluster-2)
  ✓  Row inserted: run_id=chaos-6878

Step 3 — Verify replication to all replicas
  ✓  Replica my-pg-cluster-1 has the row (1 row)
  ✓  Replica my-pg-cluster-3 has the row (1 row)

Step 4 — Kill primary pod (my-pg-cluster-2)
  ✓  Pod my-pg-cluster-2 deleted

Step 5 — Waiting for new primary election (timeout: 120s)
  →  Polling every 2s…
  ✓  New primary elected: my-pg-cluster-1  (failover in 8340ms)

Step 6 — Data integrity on new primary (my-pg-cluster-1)
  ✓  Data intact on new primary (1 row for chaos-6878)

Step 7 — Cluster topology after failover
NAME               READY   STATUS    ROLE
my-pg-cluster-1    1/1     Running   primary
my-pg-cluster-2    1/1     Running   replica
my-pg-cluster-3    1/1     Running   replica

Summary
  ✓  Run ID:         chaos-6878
  ✓  Old primary:    my-pg-cluster-2 (deleted)
  ✓  New primary:    my-pg-cluster-1
  ✓  Failover time:  8340ms

All chaos checks PASSED
```

---

## Notes

- The replication check waits 1 second before reading from replicas to account for streaming replication lag on Minikube. Increase this if you see intermittent replica failures.
- The `chaos_test` table is created with `IF NOT EXISTS` — repeated runs are safe and accumulate rows.
- Failover time is measured from pod deletion to the moment a new pod acquires the `primary` role label.