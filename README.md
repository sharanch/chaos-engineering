Resilient Data PoC (PostgreSQL HA on K8s)

A Proof of Concept (PoC) demonstrating a High-Availability (HA) PostgreSQL cluster architecture within Kubernetes. This project focuses on the "Reliability" pillar of SRE—ensuring data persistence and automatic failover in the event of infrastructure failure.
🚀 Overview

Running stateful workloads like databases on Kubernetes is notoriously difficult. This project utilizes the CloudNativePG (CNPG) operator to manage the lifecycle of a PostgreSQL cluster, providing:

    Automated Failover: Primary/Replica synchronization with automatic leader election.

    Self-Healing: Automatic recreation of failed replicas.

    Dynamic Provisioning: Automated management of Persistent Volume Claims (PVCs).

🛠 Tech Stack

    Orchestration: Kubernetes (Minikube/EKS/GKE)

    Database: PostgreSQL 16

    Operator: CloudNativePG (CNPG)

    Storage: Kubernetes Dynamic Provisioning (Standard StorageClass)

🏗 Architecture

The cluster is deployed as a 3-node architecture to ensure quorum:

    1 Primary: Handles all read/write traffic.

    2 Replicas: Maintain hot-standby copies of the data via streaming replication.

Plaintext

       [ Kubernetes Cluster ]
                 │
       ┌─────────┴─────────┐
       │  CNPG Operator    │ (Controller Loop)
       └─────────┬─────────┘
                 │
   ┌─────────────┼─────────────┐
   ▼             ▼             ▼
[Primary]     [Replica]     [Replica]
  (RW)          (RO)          (RO)
   │             │             │
 [PVC]         [PVC]         [PVC]

🧪 Chaos Testing (Validation)

To prove the "Resilience" of this setup, the following scenarios were tested:
1. Primary Node Failure

    Action: Forcefully deleted the Primary Pod (kubectl delete pod <primary-pod>).

    Observation: The CNPG operator detected the liveness failure, promoted the most up-to-date replica to Primary within seconds, and updated the Service endpoints.

    Result: Zero data loss; minimal downtime for write operations.

2. Storage Persistence

    Action: Scaled the cluster to 0 and back to 3.

    Observation: Kubernetes re-attached the existing PVCs to the new pods.

    Result: Data remained intact, proving successful state management.

⚙️ Setup Instructions

    Install the CNPG Operator:
    Bash

    kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.22.0.yaml

    Deploy the Cluster:
    Bash

    kubectl apply -f postgress-cluster.yaml

    Check Status:
    Bash

    kubectl get cluster postgres-cluster -w

📝 Key SRE Takeaways

    Operator Pattern: Moving from manual StatefulSets to Operators reduces operational overhead and human error.

    Observability: Integrated liveness/readiness probes are essential for the API server to route traffic only to healthy nodes.

    Data Integrity: Synchronous vs. Asynchronous replication trade-offs were considered to balance performance and durability.
