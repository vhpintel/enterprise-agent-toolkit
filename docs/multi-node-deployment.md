# Multi-Node Deployment Guide

This guide describes how to deploy the Intel AI for Enterprise Agent Toolkit across multiple nodes — a control-plane node running all stack services plus one or more worker nodes that host additional LLM inference workloads.

The Kubernetes layer is provisioned by **Kubespray**, which natively supports multi-node clusters. Everything above Kubernetes (LiteLLM, Langfuse, Redis, Prometheus/Grafana) runs on the cluster and is automatically distributed by Kubernetes scheduling.

---

## Prerequisites

- **Two or more Ubuntu 22.04 / 24.04 servers** on the same network with SSH reachability between them.
- **Passwordless SSH** from the control-plane node to every worker node (see the [SSH Key Setup](../README.md#ssh-key-setup) section in the main README).
- **`sudo` privileges** on all nodes.
- A [Hugging Face](https://huggingface.co) API token with read access to gated models.
- Internet access from all nodes to pull Helm charts and container images.

### Hardware (per node)

| Resource | Control-plane node | Worker node |
|---|---|---|
| CPU | 48+ cores | 48+ cores |
| RAM | 32 GB | 32 GB |
| Disk | 100 GB | 100 GB |
| OS | Ubuntu 22.04 / 24.04 | Ubuntu 22.04 / 24.04 |
| Architecture | x86_64 | x86_64 |

---

## Step 1 — Configure `hosts.yaml`

The default `core/inventory/hosts.yaml` is a single-node config pointing to `localhost`. For multi-node, edit it to list every node under the correct Kubespray groups.

### Single Master + Multiple Workers (recommended for most deployments)

```yaml
all:
  hosts:
    master1:
      ansible_host: 10.0.0.1          # control-plane private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker1:
      ansible_host: 10.0.0.2          # worker node 1 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker2:
      ansible_host: 10.0.0.3          # worker node 2 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
    kube_node:
      hosts:
        master1:
        worker1:
        worker2:
    etcd:
      hosts:
        master1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```

### Multi-Master + Multiple Workers (HA — production)

For high-availability control planes, promote additional nodes to `kube_control_plane` and `etcd`. Three control-plane nodes are the minimum for HA etcd quorum.

```yaml
all:
  hosts:
    master1:
      ansible_host: 10.0.0.1
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    master2:
      ansible_host: 10.0.0.2
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    master3:
      ansible_host: 10.0.0.3
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker1:
      ansible_host: 10.0.0.4
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker2:
      ansible_host: 10.0.0.5
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
        master2:
        master3:
    kube_node:
      hosts:
        master1:
        master2:
        master3:
        worker1:
        worker2:
    etcd:
      hosts:
        master1:
        master2:
        master3:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```

> **Note:** The node running `./deploy-agentic-stack.sh` must be able to reach all other nodes via SSH using the key specified in `ansible_ssh_private_key_file`.

---

## Step 2 — Configure `/etc/hosts` and TLS

### On every node

Add all stack subdomains pointing to the control-plane node (or load balancer IP):

```bash
# Replace 10.0.0.1 with your control-plane/LB IP
# Replace api.example.com with your actual cluster_url
sudo bash -c 'cat >> /etc/hosts <<EOF
10.0.0.1 api.example.com
10.0.0.1 trace-api.example.com
EOF'
```

### On the control-plane node — generate or supply TLS certificates

```bash
DOMAIN="api.example.com"   # replace with your cluster_url

mkdir -p ~/certs && cd ~/certs && \
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName = DNS:${DOMAIN}, DNS:trace-${DOMAIN}, DNS:*.${DOMAIN}"
```

Set the generated paths in `core/inventory/agentic-config.cfg`:

```ini
cert_file=/home/ubuntu/certs/cert.pem
key_file=/home/ubuntu/certs/key.pem
```

---

## Step 3 — Configure `agentic-config.cfg`

Open `core/inventory/agentic-config.cfg` and fill in your values:

```ini
cluster_url=api.example.com        # your domain / control-plane FQDN

cert_file=/home/ubuntu/certs/cert.pem
key_file=/home/ubuntu/certs/key.pem

hugging_face_token=hf_xxxxxxxxxxxxxxxxxxxx

models=cpu-qwen3-coder-30b      # model to deploy (see supported models)
cpu_or_gpu=cpu

# Enable/disable stack components
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_redis=on          # standalone Redis Stack in its own namespace
deploy_pgvector=off      # optional: PostgreSQL 16 + pgvector — shared vector store and long-term memory backend

```

---

## Step 4 — Deploy

Run the deployment script from the control-plane node:

```bash
chmod +x deploy-agentic-stack.sh
./deploy-agentic-stack.sh
```

Kubespray will use `core/inventory/hosts.yaml` to provision Kubernetes across all listed nodes (~15–30 min). The remaining stack components are then deployed on top.

---

## Step 5 — Verify

After deployment, confirm all nodes joined the cluster and all pods are healthy:

```bash
# All nodes should show Ready
kubectl get nodes -o wide

# All pods should be Running
kubectl get pods -A

# Retrieve the LiteLLM master key
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# Confirm the model API is responding
curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
```

---

## Adding a Worker Node to a Running Cluster

To expand a running cluster with an additional worker node:

1. Add the new node's entry to `core/inventory/hosts.yaml` under both `all.hosts` and `kube_node`.
2. Ensure passwordless SSH is set up from the control-plane node to the new node.
3. Use the interactive menu:

```bash
./deploy-agentic-stack.sh --menu
# Select: 4) Manage Cluster Nodes
#       → Add Worker Node
```

The script runs Kubespray's `cluster.yml` to join the node and re-applies the NRI balloon CPU policy if applicable.

---

## Supported Deployment Topologies

| Topology | Use case |
|---|---|
| Single node (default) | Development, testing, single-server deployments |
| 1 control-plane + N workers | Production — scale inference horizontally |
| 3 control-planes + N workers | HA production — no single point of failure on the control plane |

---

## Notes

- The **NGINX Ingress Controller** binds to the control-plane node by default. For HA deployments with multiple control-plane nodes, configure a load balancer in front and point `cluster_url` DNS to the LB IP.
- **Redis** runs as a single `StatefulSet` in the `redis` namespace. It is shared across all agent namespaces but is not clustered by default. For high-availability Redis, configure Redis Cluster or Redis Sentinel via the `core/helm-charts/redis` chart values.
- **Model weights** are pulled onto whichever node the vLLM pod is scheduled. For multi-worker setups with PVC-backed model storage, see the `modelUsePVC` option in `core/helm-charts/vllm/values.yaml`.
- Ensure all required ports are open between nodes (Kubernetes API: 6443, etcd: 2379–2380, Calico: 179, kubelet: 10250).

---

## Troubleshooting

| Symptom | Resolution |
|---|---|
| Node shows `NotReady` | Check kubelet: `systemctl status kubelet` on the affected node |
| SSH connection refused during Kubespray | Verify `ansible_host` IPs and `ansible_ssh_private_key_file` paths in `hosts.yaml` |
| Pods stuck in `Pending` | Check node resources: `kubectl describe node <node>` |
| Model pod not scheduled on worker | Confirm the worker has sufficient CPU/RAM and no taints blocking scheduling: `kubectl describe node <worker>` |

For further help, open an issue in the repository.
