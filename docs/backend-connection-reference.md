# Backend Connection Reference — Intel® Agent Toolkit

All shared backends are deployed into their own namespaces and are reachable from any workload namespace in the cluster.

## Redis (Session Memory & Caching)

| Instance | Kubernetes Service | URL | Scope |
|---|---|---|---|
| **Redis Stack** (`deploy_redis=on`) | `redis-stack-server.redis.svc.cluster.local:6379` (ClusterIP) | `redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379` | All namespaces (in-cluster only) |

Redis requires a password. The credentials and the full URL are stored in the `redis-stack-server-credentials` Secret:

```bash
# Full connection URL (preferred — do not hardcode the password)
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d

# Password only
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d

# Quick connectivity test
kubectl exec -n redis redis-stack-server-0 -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
# PONG
```

> The `default:` username in the URL is required — Redis 6+ rejects the `redis://:<password>@...` form with `WRONGPASS`.
> The Service is `ClusterIP` and a NetworkPolicy is applied; Redis is not reachable from outside the cluster. Use `kubectl port-forward` for local access instead of changing the Service type.

## Agent Sandbox (Sandboxed Execution)

Enabled with `deploy_agent_sandbox=on`. See [agent-sandbox.md](agent-sandbox.md) for full details.

| Resource | Value |
|---|---|
| **Namespace** | `agent-sandbox` |
| **Router service** | `sandbox-router-svc.agent-sandbox.svc.cluster.local:8080` |
| **SDK** | `pip install k8s-agent-sandbox` |
| **Default template** | `python-sandbox-template` (namespace: `agent-sandbox`) |

```bash
# Quick health check (requires port-forward or in-cluster)
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

## OpenShell (Policy-Enforced Sandboxes)

Enabled with `deploy_openshell=on` (requires `deploy_agent_sandbox=on`). See [openshell.md](openshell.md) for full details.

| Resource | Value |
|---|---|
| **Gateway namespace** | `openshell-system` |
| **Gateway service** | `openshell.openshell-system.svc.cluster.local:8080` (gRPC, mTLS) |
| **Sandbox namespace** | `openshell-sandboxes` |
| **Client mTLS bundle** | Secret `openshell-client-tls` in `openshell-system` |
| **CLI** | [OpenShell v0.0.116 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.116) |
| **GenAI provider** | `genai-gateway` (attach with `openshell sandbox create --provider genai-gateway`) |

```bash
# Admin access (ClusterIP only)
kubectl port-forward -n openshell-system svc/openshell 8080:8080 &
```

## PostgreSQL + pgvector (Vector Store & Long-Term Memory)

Enabled with `deploy_pgvector=on`. See [README.md](README.md#step-2b--postgresql--pgvector-vector-store--long-term-memory) for deployment details.

| Resource | Value |
|---|---|
| **Namespace** | `pgvector` |
| **Host** | `pgvector.pgvector.svc.cluster.local` |
| **Port** | `5432` |
| **Database** | `agentdb` |
| **User** | `agentuser` |
| **Connection string** | `postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb` |
| **Credentials secret** | `kubectl get secret pgvector-credentials -n pgvector -o jsonpath='{.data.DATABASE_URL}' \| base64 -d` |

## Amazon OpenSearch Service (Managed Memory Backend)

Enabled with `deploy_opensearch=on`. Replaces **both** in-cluster memory tiers — the standalone Redis Stack (short-term) and PostgreSQL + pgvector (long-term) — so set `deploy_redis=off` and `deploy_pgvector=off` alongside it. The domain is provisioned outside the cluster (CloudFormation, Terraform, or by hand); the toolkit discovers it, creates the indices, and publishes the connection details as a Secret.

| Resource | Value |
|---|---|
| **Namespace** | `opensearch` |
| **Credentials secret** | `opensearch-credentials` |
| **Short-term index** | `agent-session-memory` |
| **Long-term index** | `agent-knowledge` (`knn_vector` + BM25) |
| **Hybrid search pipeline** | `hybrid-rag-pipeline` |
| **TTL reaper** | CronJob `opensearch-session-ttl`, every 15 min |
| **Default embedding model** | `amazon.titan-embed-text-v2:0` (1024 dimensions) |

```bash
# Full connection URL (preferred — do not hardcode the password)
kubectl get secret opensearch-credentials -n opensearch \
  -o jsonpath='{.data.OPENSEARCH_URL}' | base64 -d

# Endpoint without credentials, for clients that take user/password separately
kubectl get secret opensearch-credentials -n opensearch \
  -o jsonpath='{.data.OPENSEARCH_ENDPOINT}' | base64 -d

# Quick connectivity test
OS=$(kubectl get secret opensearch-credentials -n opensearch \
  -o jsonpath='{.data.OPENSEARCH_URL}' | base64 -d)
curl -s "$OS/_cluster/health" | jq .status
# "yellow"   <- expected on a single-node domain: replicas cannot be allocated
```

### Two behavioural differences from Redis

**1. Read-after-write.** `_search` is near-real-time (~1 s refresh interval), so a document written and immediately searched for may not be found. Reads of session state must use the real-time document `GET`, which serves from the translog:

```
GET /agent-session-memory/_doc/<id>      <- immediately consistent
GET /agent-session-memory/_search        <- ~1s eventually consistent
```

This is also why `agent-session-memory` is a single concrete index rather than an ISM rollover alias — a real-time `GET` by `_id` cannot resolve an alias spanning multiple indices. Anything needing genuinely sub-millisecond immediate reads belongs on Amazon ElastiCache, not here.

**2. TTL.** OpenSearch has no per-document expiry equivalent to Redis key expiry, and ISM operates on whole indices rather than documents. Writers stamp `expires_at`; readers filter on it; the `opensearch-session-ttl` CronJob reaps expired documents with `_delete_by_query` every 15 minutes, and also sweeps documents older than `opensearch_session_ttl_hours` (default 24) that were written without an `expires_at` stamp.

### Hybrid retrieval

k-NN cosine scores and BM25 scores are on incompatible scales, so a hybrid query **must** pass `search_pipeline=hybrid-rag-pipeline`. The pipeline min-max normalises each sub-query score and combines them with a weighted arithmetic mean (0.7 vector / 0.3 lexical). Without it, whichever scale happens to be larger dominates the ranking.

```bash
curl -s "$OS/agent-knowledge/_search?search_pipeline=hybrid-rag-pipeline" \
  -H 'Content-Type: application/json' -d '{
    "size": 3,
    "_source": ["doc_id","title"],
    "query": { "hybrid": { "queries": [
      { "match": { "text": "how do I read session state consistently" } },
      { "knn": { "embedding": { "vector": [ /* 1024 floats */ ], "k": 5 } } }
    ] } }
  }' | jq '.hits.hits[]._source'
```

Get the query vector from the gateway, which routes to Amazon Bedrock:

```bash
kubectl -n genai-gateway exec deploy/genai-gateway-deployment -- curl -sS \
  -X POST localhost:4000/v1/embeddings \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"amazon.titan-embed-text-v2:0","input":"your question"}' \
  | jq -c '.data[0].embedding'
```

> The `knn_vector` dimension is fixed when the index is created and cannot be altered. Changing `opensearch_embed_model` therefore requires deleting and recreating `agent-knowledge`. The controller validates the returned vector length against the mapping and fails loudly on a mismatch rather than letting every bulk index fail with an opaque mapper error.

> Behind a forward proxy, the domain endpoint must be in `no_proxy` **by hostname**. A VPC domain resolves to private subnet addresses, but proxy libraries match `no_proxy` against the request hostname *before* resolving DNS, so a CIDR entry never matches `vpc-<domain>-<hash>.<region>.es.amazonaws.com` — the request is handed to a proxy with no route to it and blackholes. `read_config_file()` appends `.es.amazonaws.com` and `.aos.amazonaws.com` when `deploy_opensearch=on`.

### Redis instances that remain

Migrating agent memory to OpenSearch retires **only** the standalone Redis Stack. Three protocol-level consumers keep their own instances and are unaffected:

| Instance | Role | Replaceable by OpenSearch? |
|---|---|---|
| Redis bundled with the GenAI Gateway | Router state, response cache, rate-limit counters | **No** — Redis protocol only; disabling it breaks `usage-based-routing-v2` and the gateway's blocking startup probe |
| Redis bundled with Flowise | Worker queue | **No** — upstream component |
| Valkey bundled with Langfuse | Tracing queue | **No** — upstream component |

Eliminating those means moving them to Amazon ElastiCache, which is tracked separately.

## KubeRay (Distributed Computing)

Enabled with `deploy_kuberay=on`. Tuned via `core/inventory/kuberay-config.yaml`. See [kuberay.md](kuberay.md) for the full guide.

| Resource | Value |
|---|---|
| **Namespace** | `ray-system` *(default; set via `kuberay-config.yaml`)* |
| **Ray Client API** | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| **Ray Dashboard** | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265` |
| **Dashboard (local)** | `kubectl port-forward svc/ray-cluster-head-svc 8265:8265 -n ray-system` |

```bash
# Verify all Ray pods are Running
kubectl get pods -n ray-system

# Quick Python connectivity test (from inside the cluster or via port-forward)
python3 -c "
import ray
ray.init('ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001')
print(ray.cluster_resources())
"
```

## Flowise (Agent Builder)

Enabled with `deploy_flowise=on`. See [flowise.md](flowise.md) for the full guide.

| Resource | Value |
|---|---|
| **Namespace** | `flowise` |
| **Flowise service** | `flowise.flowise.svc.cluster.local:3000` |
| **Flowise admin UI** | `https://flowise-<cluster_url>` |

```bash
# Check pods
kubectl get pods -n flowise

# Retrieve the Flowise API key
grep '^flowise_api_key:' core/inventory/metadata/vault.yml | awk -F'"' '{print $2}'
```