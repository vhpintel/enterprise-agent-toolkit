# Agent Sandbox

Agent Sandbox provides **isolated, ephemeral Kubernetes pod environments** for
safe code execution by AI agents. Each sandbox is a fully isolated pod with its
own filesystem, network namespace, and process tree — the agent can run
arbitrary code, install packages, and write files without ever touching the host
or other workloads.

The implementation is based on
[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox).

---

## Architecture

```
Agent (e.g. Coding Agent)
        │
        │  HTTP  (in-cluster DNS)
        ▼
sandbox-router-svc.agent-sandbox.svc.cluster.local:8080
        │
        │  creates SandboxClaim CR via Kubernetes API
        ▼
  agent-sandbox-controller  (agent-sandbox namespace)
        │
        │  spawns pod from SandboxTemplate spec
        ▼
  sandbox-claim-<id>  (pod in agent-sandbox namespace)
        │
        │  NetworkPolicy: allows ingress from app=sandbox-router
        │  in the SAME namespace only
        ▼
  python-runtime-sandbox — uvicorn on :8888
        POST /execute  {"command": "..."}  →  {stdout, stderr, exit_code}
```

**Key design points:**

- All components live in the **`agent-sandbox`** namespace so the
  controller-generated `NetworkPolicy` (which allows ingress only from pods
  labelled `app=sandbox-router` in the same namespace) applies correctly.
- The **sandbox-router** is the only component that calls the Kubernetes API —
  client pods (like the Coding Agent) need no RBAC of their own.
- The **python-runtime-sandbox** image is built locally and injected into
  containerd at deploy time. There is no pre-built image in any registry.

---

## Deployed Components

| Component | Kind | Namespace | Notes |
|---|---|---|---|
| `agent-sandbox-controller` | Deployment | `agent-sandbox` | Helm chart from upstream source |
| CRDs | ClusterScoped | — | `sandboxes`, `sandboxtemplates`, `sandboxclaims`, `sandboxwarmpools` |
| `sandbox-router-deployment` | Deployment (×2) | `agent-sandbox` | Locally built — routes HTTP → sandbox pods |
| `sandbox-router-svc` | Service | `agent-sandbox` | ClusterIP :8080 |
| `python-sandbox-template` | SandboxTemplate CR | `agent-sandbox` | Default template using `python-runtime-sandbox` image |
| `sandbox-router` image | containerd k8s.io | — | Built from `clients/python/agentic-sandbox-client/sandbox-router/Dockerfile` |
| `python-runtime-sandbox` image | containerd k8s.io | — | Built from `examples/python-runtime-sandbox/Dockerfile` |

---

## Configuration

### Enable in `core/inventory/agentic-config.cfg`

```ini
deploy_agent_sandbox=on
```

Set to `off` to skip deployment. On re-runs, if the `agent-sandbox` namespace
already exists the deployment is automatically skipped (resume mode).

### Version pin in `core/inventory/metadata/agentic-metadata.cfg`

```ini
agent_sandbox_version="v0.4.6"
```

This controls the Git tag cloned from the upstream repository and the image
tag applied to the locally-built images. Update the version here to upgrade.

---

## Deployment

Agent Sandbox is deployed as part of the standard stack run:

```bash
# core/inventory/agentic-config.cfg
deploy_agent_sandbox=on

./deploy-agentic-stack.sh
```

The deploy script runs 8 steps:

| Step | Action |
|---|---|
| 1 | Install Helm, nerdctl, BuildKit; start buildkitd |
| 2 | Shallow-clone upstream source at the pinned version |
| 3 | `kubectl apply -f helm/crds/` (upgrade-safe CRD installation) |
| 4 | `helm upgrade --install agent-sandbox helm/` into `agent-sandbox` namespace |
| 5 | Build `sandbox-router:<version>` image into containerd `k8s.io` namespace |
| 6 | Build `python-runtime-sandbox:<version>` image into containerd |
| 7 | Apply patched `sandbox_router.yaml` to `agent-sandbox` namespace |
| 8 | Apply `core/helm-charts/agent-sandbox/default-templates.yaml` (SandboxTemplate) |

---

## Verification

```bash
# All components should be Running
kubectl get pods -n agent-sandbox

# Confirm CRDs are registered
kubectl api-resources | grep sandbox

# Check the SandboxTemplate exists
kubectl get sandboxtemplate -n agent-sandbox

# Quick end-to-end health check via the router
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

---

## Default SandboxTemplate

The stack ships one template out of the box:
`core/helm-charts/agent-sandbox/default-templates.yaml`

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: python-sandbox-template
  namespace: agent-sandbox
spec:
  service: true          # headless Service created per pod — required for SDK DNS mode
  podTemplate:
    spec:
      containers:
      - name: runtime
        image: python-runtime-sandbox:<version>
        imagePullPolicy: Never
        ports:
        - name: api
          containerPort: 8888
          protocol: TCP
        resources:
          requests: { cpu: "250m", memory: "256Mi" }
          limits:   { cpu: "1000m", memory: "1Gi" }
        securityContext:
          allowPrivilegeEscalation: false
```

The `python-runtime-sandbox` image exposes a FastAPI server on port 8888:

```
POST /execute
Body: {"command": "<shell command>"}
Response: {"stdout": "...", "stderr": "...", "exit_code": 0}
```

---

## Adding a Custom SandboxTemplate

You can add any number of templates for different runtimes (Node.js, R, Java,
etc.) by creating a new `SandboxTemplate` CR.

### 1. Build and push (or inject) your runtime image

The runtime image must expose:
- `POST /execute` → `{stdout, stderr, exit_code}` — same API as `python-runtime-sandbox`

For local (no-registry) deployments, build into containerd with nerdctl:

```bash
sudo nerdctl --namespace k8s.io build \
  --tag my-node-sandbox:v1.0 \
  ./path/to/my-dockerfile-dir
```

### 2. Create the SandboxTemplate manifest

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxTemplate
metadata:
  name: node-sandbox-template
  namespace: agent-sandbox   # must match the namespace where sandboxes will be created
spec:
  service: true
  podTemplate:
    spec:
      containers:
      - name: runtime
        image: my-node-sandbox:v1.0
        imagePullPolicy: Never   # for locally injected images
        ports:
        - name: api
          containerPort: 8888
          protocol: TCP
        resources:
          requests: { cpu: "250m", memory: "256Mi" }
          limits:   { cpu: "1000m", memory: "1Gi" }
        securityContext:
          allowPrivilegeEscalation: false
```

### 3. Apply it

```bash
kubectl apply -f node-sandbox-template.yaml
kubectl get sandboxtemplate -n agent-sandbox
```

### 4. Use it from the SDK

```python
sandbox = client.create_sandbox(
    template="node-sandbox-template",
    namespace="agent-sandbox",
)
```

---

## Using the SDK (`k8s-agent-sandbox`)

Install the SDK:

```bash
pip install k8s-agent-sandbox
```

Official documentation: https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client

### From outside the cluster (development / local testing)

Use **Tunnel Mode** — the SDK opens a `kubectl port-forward` automatically, or
you can port-forward manually and use **Advanced Mode**.

**Option A — Tunnel Mode (auto port-forward):**

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxLocalTunnelConnectionConfig

client = SandboxClient(
    connection_config=SandboxLocalTunnelConnectionConfig()
    # automatically tunnels to svc/sandbox-router-svc in the default namespace;
    # pass namespace="agent-sandbox" to target our deployment:
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("python3 --version")
    print(result.stdout)
finally:
    sandbox.terminate()
```

**Option B — Advanced Mode (manual port-forward):**

```bash
# Terminal 1 — keep port-forward running
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080
```

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.connector import SandboxDirectConnectionConfig

client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://localhost:8080"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("echo 'Hello from Agent Sandbox!'")
    print(result.stdout)    # Hello from Agent Sandbox!

    result = sandbox.commands.run("pip install requests && python3 -c 'import requests; print(requests.__version__)'")
    print(result.stdout)
finally:
    sandbox.terminate()
```

### From inside the cluster (agent pods)

Use **Advanced Mode** with the sandbox-router's in-cluster DNS URL.
No RBAC changes are needed — the router handles all Kubernetes API calls.

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.connector import SandboxDirectConnectionConfig

client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("python3 -c \"print('Hello from in-cluster sandbox!')\"")
    print(result.stdout)
finally:
    sandbox.terminate()
```

This is exactly how an agent using the sandbox executes code.

### Session sandbox pattern (stateful across calls)

For agents that need state to persist across multiple tool invocations
(installed packages, defined variables), create the sandbox once and reuse it:

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.connector import SandboxDirectConnectionConfig

_client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
    )
)
_sandbox = None

def get_sandbox():
    global _sandbox
    if _sandbox is None or not _sandbox.is_active:
        _sandbox = _client.create_sandbox(
            template="python-sandbox-template",
            namespace="agent-sandbox",
        )
    return _sandbox

# First call — installs package
get_sandbox().commands.run("pip install pandas")

# Second call — package is still available
result = get_sandbox().commands.run("python3 -c 'import pandas; print(pandas.__version__)'")
print(result.stdout)

# Clean up
get_sandbox().terminate()
_sandbox = None
```

---

## WarmPools (pre-warmed sandboxes)

WarmPools keep a set of sandbox pods pre-created and idle so agents receive a
sandbox instantly without waiting for pod scheduling and image pull.

```yaml
apiVersion: extensions.agents.x-k8s.io/v1alpha1
kind: SandboxWarmPool
metadata:
  name: python-pool
  namespace: agent-sandbox
spec:
  size: 3                          # number of pre-warmed pods to maintain
  templateRef:
    name: python-sandbox-template  # must exist in the same namespace
```

Apply:

```bash
kubectl apply -f warmpool.yaml
kubectl get sandboxwarmpool -n agent-sandbox
# NAME           SIZE   READY
# python-pool    3      3
```

When an agent calls `create_sandbox`, the controller assigns a pre-warmed pod
immediately and refills the pool in the background.

> WarmPool support requires `controller.extensions: true` in
> `core/helm-charts/agent-sandbox/values.yaml` (already set by default).

---

## Re-run Safety

| Operation | Behaviour |
|---|---|
| `deploy_agent_sandbox=on` on a running stack | `helm upgrade --install` is idempotent; CRDs are re-applied with `kubectl apply` (safe for upgrades) |
| Image already in containerd | Build step is skipped automatically |
| Source already cloned | Clone step is skipped; existing `/tmp/agent-sandbox-build-<version>` reused |
| Namespace already exists | `--create-namespace` + `--set namespace.create=false` prevent duplicate-namespace errors |
| Resume mode | If `agent-sandbox` namespace exists, `_auto_skip_deployed_components()` sets `deploy_agent_sandbox=off` for that run |

---

## Upgrading

1. Update `agent_sandbox_version` in `core/inventory/metadata/agentic-metadata.cfg`
2. Re-run `./deploy-agentic-stack.sh` — the script clones the new version, applies CRDs, upgrades the Helm release, rebuilds images, and re-applies the router and SandboxTemplate

> CRDs are always applied with `kubectl apply` (not through Helm's CRD lifecycle), so CRD upgrades are handled correctly.

---

## References

- [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) — upstream controller
- [k8s-agent-sandbox Python SDK README](https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client/README.md)
- [PyPI: k8s-agent-sandbox](https://pypi.org/project/k8s-agent-sandbox/)
