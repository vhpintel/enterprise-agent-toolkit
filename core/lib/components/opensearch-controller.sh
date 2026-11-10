#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_opensearch_controller
#
# Binds the "Memory, State & Context" provider block to an EXISTING Amazon
# OpenSearch Service domain, replacing the in-cluster Redis Stack (short-term)
# and PostgreSQL + pgvector (long-term) backends.
#
# Unlike deploy_redis_controller / deploy_pgvector_controller this installs no
# datastore Helm chart -- the datastore is a managed AWS service provisioned
# outside the cluster (by CloudFormation, Terraform, or by hand). This function
# discovers it, provisions the indices, and publishes the connection details as
# a Kubernetes Secret so workloads consume it exactly the way they consumed
# redis-stack-server-credentials:
#
#   kubectl get secret opensearch-credentials -n opensearch \
#     -o jsonpath='{.data.OPENSEARCH_URL}' | base64 -d
#
# Two indices are created on the one domain:
#   agent-session-memory  short-term working context (replaces Redis+RediSearch)
#   agent-knowledge       long-term knowledge, k-NN + BM25 hybrid RAG (replaces pgvector)
#
# IMPORTANT -- two behavioural differences from Redis that callers must respect:
#
#   1. READ-AFTER-WRITE. OpenSearch _search is near-real-time (~1s refresh), so
#      a document written and immediately searched for may not be found. Reads
#      of session state MUST use the real-time document GET, which serves from
#      the translog:
#          GET /agent-session-memory/_doc/<id>      <-- immediately consistent
#          GET /agent-session-memory/_search        <-- ~1s eventually consistent
#      Anything needing genuinely sub-millisecond immediate reads belongs on
#      ElastiCache, not here.
#
#   2. TTL. OpenSearch has no per-document expiry equivalent to Redis key
#      expiry, and ISM operates on whole indices rather than documents. Writers
#      therefore stamp `expires_at`, readers filter on it, and a CronJob
#      (opensearch-session-ttl) reaps expired documents with _delete_by_query.
#      Deliberately NOT done with an ISM rollover policy: rollover would make
#      `agent-session-memory` an alias spanning several concrete indices, and a
#      real-time GET by _id cannot resolve a multi-index alias -- which would
#      break guarantee (1) above.
#
# Config (core/inventory/agentic-config.cfg):
#   deploy_opensearch=on
#   opensearch_domain_name=<domain name>        # required
#   opensearch_secret_arn=<secrets manager arn> # required (master credentials)
#   opensearch_region=<region>                  # optional, defaults to AWS_REGION
#   opensearch_session_ttl_hours=24
#   opensearch_embed_model=amazon.titan-embed-text-v2:0
#   opensearch_seed_sample_data=on
#
# The master password is read from AWS Secrets Manager at deploy time and is
# never written to agentic-config.cfg -- read_config_file() pipes values through
# xargs, which mangles quotes and shell metacharacters in generated passwords.
#
# Prerequisites:
#   * Kubernetes is running  (kubectl get nodes)
#   * awscli v2, jq and curl on PATH
#   * The host role allows opensearch:DescribeDomain,
#     secretsmanager:GetSecretValue and es:ESHttp* on the domain
#   * SCRIPT_DIR points to the core/ directory
#   * The GenAI Gateway is already deployed when seeding sample data (the seed
#     path embeds through the gateway, i.e. through Amazon Bedrock)
# ---------------------------------------------------------------------------

# Fixed rather than configurable so the Secret contract stays stable for
# consumers; the values are published in the Secret regardless.
OPENSEARCH_NAMESPACE="${OPENSEARCH_NAMESPACE:-opensearch}"
OPENSEARCH_SECRET_NAME="${OPENSEARCH_SECRET_NAME:-opensearch-credentials}"
OPENSEARCH_SHORT_TERM_INDEX="${OPENSEARCH_SHORT_TERM_INDEX:-agent-session-memory}"
OPENSEARCH_KNOWLEDGE_INDEX="${OPENSEARCH_KNOWLEDGE_INDEX:-agent-knowledge}"
OPENSEARCH_HYBRID_PIPELINE="${OPENSEARCH_HYBRID_PIPELINE:-hybrid-rag-pipeline}"
OPENSEARCH_TTL_CRONJOB="${OPENSEARCH_TTL_CRONJOB:-opensearch-session-ttl}"

# Dimensions of the supported Bedrock embedding models. A k-NN mapping is fixed
# at index-creation time and cannot be altered afterwards, so a mismatch with
# the model actually registered in the gateway surfaces much later as an opaque
# mapper error. Fail fast on an unknown model instead of guessing.
_opensearch_embed_dims() {
    case "$1" in
        amazon.titan-embed-text-v2:0)   echo 1024 ;;
        amazon.titan-embed-text-v1)     echo 1536 ;;
        cohere.embed-english-v3)        echo 1024 ;;
        cohere.embed-multilingual-v3)   echo 1024 ;;
        *)                              echo "" ;;
    esac
}

# curl against the domain. Basic auth over HTTPS; the domain enforces TLS.
# Echoes the response body and leaves the status where _os_http_code can read it,
# so callers can treat "already exists" as success.
#
# The status goes through a FILE, not a variable: every caller invokes this as
# resp=$(_opensearch_api ...), and command substitution runs the function in a
# subshell, so any variable it assigns is discarded when that subshell exits.
# The symptom was "cannot reach the domain (HTTP )" against a healthy domain.
#
# _os_user / _os_pass / _os_url are declared `local` in
# deploy_opensearch_controller and reached here through bash's dynamic scoping,
# which keeps the credentials off the global environment.
_OS_CODE_FILE="${TMPDIR:-/tmp}/.eat-opensearch-http-code"
_os_http_code() { cat "${_OS_CODE_FILE}" 2>/dev/null; }
_opensearch_api() {
    local method="$1" path="$2" body="${3:-}"
    local out
    if [[ -n "${body}" ]]; then
        out=$(curl -sS -u "${_os_user}:${_os_pass}" -X "${method}" \
            -H 'Content-Type: application/json' \
            -w '\n%{http_code}' --max-time 120 \
            "${_os_url}${path}" -d "${body}" 2>&1)
    else
        out=$(curl -sS -u "${_os_user}:${_os_pass}" -X "${method}" \
            -w '\n%{http_code}' --max-time 120 \
            "${_os_url}${path}" 2>&1)
    fi
    printf '%s' "${out}" | tail -n1 > "${_OS_CODE_FILE}"
    printf '%s' "${out}" | sed '$d'
}

# Treat 200/201 as created and an existing-resource conflict as already-done, so
# the controller is safe to re-run (execute_and_check retries, and stacks get
# redeployed in place).
_opensearch_put_idempotent() {
    local what="$1" path="$2" body="$3"
    local resp
    resp=$(_opensearch_api PUT "${path}" "${body}")
    case "$(_os_http_code)" in
        200|201)
            echo "${GREEN}    created ${what}${NC}"
            ;;
        400)
            if grep -qE 'resource_already_exists_exception|already exists|version_conflict' <<<"${resp}"; then
                echo "${YELLOW}    ${what} already exists - leaving as is${NC}"
            else
                echo "${RED}    ERROR creating ${what} (HTTP 400): ${resp}${NC}"
                return 1
            fi
            ;;
        409)
            echo "${YELLOW}    ${what} already exists - leaving as is${NC}"
            ;;
        *)
            echo "${RED}    ERROR creating ${what} (HTTP $(_os_http_code)): ${resp}${NC}"
            return 1
            ;;
    esac
    return 0
}

deploy_opensearch_controller() {
    local domain_name="${opensearch_domain_name:-}"
    local secret_arn="${opensearch_secret_arn:-}"
    local ttl_hours="${opensearch_session_ttl_hours:-24}"
    local embed_model="${opensearch_embed_model:-amazon.titan-embed-text-v2:0}"
    local seed="${opensearch_seed_sample_data:-yes}"
    local region="${opensearch_region:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"

    echo "${BLUE}======================================================${NC}"
    echo "${BLUE}  Binding Memory Backend to Amazon OpenSearch Service${NC}"
    echo "${BLUE}======================================================${NC}"

    # ---- validate configuration --------------------------------------------
    if [[ -z "${domain_name}" ]]; then
        echo "${RED}ERROR: opensearch_domain_name is not set in agentic-config.cfg.${NC}"
        echo "${RED}       Set it to the name of an existing Amazon OpenSearch Service domain.${NC}"
        exit 1
    fi
    if [[ -z "${secret_arn}" ]]; then
        echo "${RED}ERROR: opensearch_secret_arn is not set in agentic-config.cfg.${NC}"
        echo "${RED}       Set it to the Secrets Manager ARN holding the domain master credentials.${NC}"
        exit 1
    fi
    if [[ ! "${ttl_hours}" =~ ^[0-9]+$ ]] || (( ttl_hours < 1 )); then
        echo "${RED}ERROR: opensearch_session_ttl_hours must be a positive integer (got '${ttl_hours}').${NC}"
        exit 1
    fi
    local _bin
    for _bin in aws jq curl kubectl; do
        if ! command -v "${_bin}" &>/dev/null; then
            echo "${RED}ERROR: '${_bin}' is required by the OpenSearch provider but is not on PATH.${NC}"
            exit 1
        fi
    done

    local embed_dims
    embed_dims=$(_opensearch_embed_dims "${embed_model}")
    if [[ -z "${embed_dims}" ]]; then
        echo "${RED}ERROR: unknown embedding model '${embed_model}'.${NC}"
        echo "${RED}       The k-NN vector dimension cannot be changed after the index is created,${NC}"
        echo "${RED}       so it must be known up front. Add the model to _opensearch_embed_dims()${NC}"
        echo "${RED}       in lib/components/opensearch-controller.sh, or set opensearch_embed_model${NC}"
        echo "${RED}       to one of: amazon.titan-embed-text-v2:0, amazon.titan-embed-text-v1,${NC}"
        echo "${RED}       cohere.embed-english-v3, cohere.embed-multilingual-v3.${NC}"
        exit 1
    fi

    local aws_args=()
    [[ -n "${region}" ]] && aws_args+=(--region "${region}")

    # ---- 1/6 wait for the domain to finish provisioning --------------------
    # A domain takes 15-30 minutes to create. Callers are expected to start it in
    # parallel with the cluster build (the CloudFormation template does), so by
    # the time this runs it is usually ready -- but poll rather than assume.
    echo "${CYAN}[1/6] Waiting for OpenSearch domain '${domain_name}' to become available...${NC}"
    local waited=0 max_wait=1800 poll=20
    local processing="" endpoint="" describe
    while true; do
        if ! describe=$(aws "${aws_args[@]}" opensearch describe-domain \
                --domain-name "${domain_name}" 2>&1); then
            echo "${RED}ERROR: cannot describe OpenSearch domain '${domain_name}':${NC}"
            echo "${RED}${describe}${NC}"
            echo "${RED}       Check the domain name, the region (${region:-<unset>}), and that this${NC}"
            echo "${RED}       host's IAM role allows opensearch:DescribeDomain.${NC}"
            exit 1
        fi
        processing=$(jq -r '.DomainStatus.Processing' <<<"${describe}")
        # A VPC domain publishes its data-plane endpoint under Endpoints.vpc;
        # a public domain uses the flat Endpoint field.
        endpoint=$(jq -r '.DomainStatus.Endpoints.vpc // .DomainStatus.Endpoint // empty' <<<"${describe}")
        if [[ "${processing}" == "false" && -n "${endpoint}" ]]; then
            break
        fi
        if (( waited >= max_wait )); then
            echo "${RED}ERROR: domain '${domain_name}' still Processing=${processing} after ${max_wait}s.${NC}"
            exit 1
        fi
        echo "${CYAN}      ...still provisioning (Processing=${processing}, ${waited}s elapsed)${NC}"
        sleep "${poll}"
        waited=$(( waited + poll ))
    done
    local _os_url="https://${endpoint}"
    echo "${GREEN}      endpoint: ${endpoint}${NC}"

    # A VPC domain resolves to private subnet addresses, but proxy libraries
    # match no_proxy on the HOSTNAME before resolving DNS -- so a CIDR entry can
    # never match vpc-*.es.<region>.amazonaws.com and the request is handed to
    # the corporate proxy, which has no route to it. Bypass it explicitly.
    if [[ -n "${http_proxy:-}${https_proxy:-}" ]]; then
        export no_proxy="${no_proxy:+${no_proxy},}${endpoint}"
        export NO_PROXY="${no_proxy}"
        echo "${CYAN}      added ${endpoint} to no_proxy (a proxy is in use)${NC}"
    fi

    # ---- 2/6 master credentials from Secrets Manager -----------------------
    echo "${CYAN}[2/6] Reading domain master credentials from Secrets Manager...${NC}"
    local secret_json
    if ! secret_json=$(aws "${aws_args[@]}" secretsmanager get-secret-value \
            --secret-id "${secret_arn}" --query SecretString --output text 2>&1); then
        echo "${RED}ERROR: cannot read secret '${secret_arn}':${NC}"
        echo "${RED}${secret_json}${NC}"
        echo "${RED}       This host's IAM role needs secretsmanager:GetSecretValue on that secret.${NC}"
        exit 1
    fi
    local _os_user _os_pass
    _os_user=$(jq -r '.username // empty' <<<"${secret_json}")
    _os_pass=$(jq -r '.password // empty' <<<"${secret_json}")
    unset secret_json
    if [[ -z "${_os_user}" || -z "${_os_pass}" ]]; then
        echo "${RED}ERROR: secret '${secret_arn}' has no 'username' and 'password' keys.${NC}"
        exit 1
    fi

    # Prove credentials and the network path work before creating anything.
    local health
    health=$(_opensearch_api GET /_cluster/health)
    if [[ "$(_os_http_code)" != "200" ]]; then
        echo "${RED}ERROR: cannot reach the domain (HTTP $(_os_http_code)): ${health}${NC}"
        echo "${RED}       Check the security group allows 443 from this host, that the domain${NC}"
        echo "${RED}       access policy permits it, and that no_proxy covers ${endpoint}.${NC}"
        exit 1
    fi
    echo "${GREEN}      cluster status: $(jq -r '.status' <<<"${health}")${NC}"

    # ---- 3/6 indices -------------------------------------------------------
    echo "${CYAN}[3/6] Creating indices...${NC}"

    # Short-term working context. No k-NN: this tier does keyed lookups and
    # lexical filtering, which is what Redis + RediSearch served for it.
    # Single concrete index (not a rollover alias) so real-time GET by _id works.
    _opensearch_put_idempotent "index ${OPENSEARCH_SHORT_TERM_INDEX}" \
        "/${OPENSEARCH_SHORT_TERM_INDEX}" '{
      "settings": {
        "index": {
          "number_of_shards": 1,
          "number_of_replicas": 0,
          "refresh_interval": "1s"
        }
      },
      "mappings": {
        "properties": {
          "session_id":  { "type": "keyword" },
          "agent_id":    { "type": "keyword" },
          "user_id":     { "type": "keyword" },
          "role":        { "type": "keyword" },
          "turn":        { "type": "integer" },
          "content":     { "type": "text" },
          "metadata":    { "type": "object", "enabled": false },
          "created_at":  { "type": "date" },
          "expires_at":  { "type": "date" }
        }
      }
    }' || exit 1

    # Long-term knowledge. index.knn enables the k-NN plugin for this index; the
    # same document carries `text` so one hybrid query can score both the vector
    # neighbourhood and the BM25 lexical match.
    _opensearch_put_idempotent "index ${OPENSEARCH_KNOWLEDGE_INDEX} (k-NN, dim=${embed_dims})" \
        "/${OPENSEARCH_KNOWLEDGE_INDEX}" '{
      "settings": {
        "index": {
          "knn": true,
          "number_of_shards": 1,
          "number_of_replicas": 0,
          "refresh_interval": "1s"
        }
      },
      "mappings": {
        "properties": {
          "doc_id":     { "type": "keyword" },
          "title":      { "type": "text" },
          "text":       { "type": "text" },
          "source":     { "type": "keyword" },
          "tags":       { "type": "keyword" },
          "created_at": { "type": "date" },
          "embedding": {
            "type": "knn_vector",
            "dimension": '"${embed_dims}"',
            "method": {
              "name": "hnsw",
              "space_type": "cosinesimil",
              "engine": "lucene",
              "parameters": { "ef_construction": 128, "m": 16 }
            }
          }
        }
      }
    }' || exit 1

    # ---- 4/6 hybrid search pipeline ----------------------------------------
    echo "${CYAN}[4/6] Creating the hybrid-search pipeline...${NC}"

    # The normalization processor is what makes hybrid search work at all: k-NN
    # cosine scores and BM25 scores are on incompatible scales, so each
    # sub-query is min-max normalised before the scores are combined. Without
    # it the result is dominated by whichever scale happens to be larger.
    _opensearch_put_idempotent "search pipeline ${OPENSEARCH_HYBRID_PIPELINE}" \
        "/_search/pipeline/${OPENSEARCH_HYBRID_PIPELINE}" '{
      "description": "Hybrid RAG: normalise and blend k-NN semantic scores with BM25 lexical scores",
      "phase_results_processors": [
        {
          "normalization-processor": {
            "normalization": { "technique": "min_max" },
            "combination": {
              "technique": "arithmetic_mean",
              "parameters": { "weights": [0.7, 0.3] }
            }
          }
        }
      ]
    }' || exit 1

    # ---- 5/6 publish the connection Secret + TTL reaper --------------------
    # Same contract as redis-stack-server-credentials: a Secret holding a URL
    # plus credentials, so agent workloads need no code change beyond key names.
    echo "${CYAN}[5/6] Publishing '${OPENSEARCH_SECRET_NAME}' Secret in namespace '${OPENSEARCH_NAMESPACE}'...${NC}"
    kubectl create namespace "${OPENSEARCH_NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # The Secret manifest is assembled here and piped to kubectl rather than
    # built with `kubectl create secret --from-literal`, because --from-literal
    # puts the password in the process argument list, which is world-readable
    # via ps(1) for the lifetime of the call.
    _opensearch_apply_secret "${endpoint}" "${_os_url}" "${_os_user}" "${_os_pass}" \
        "${embed_model}" "${embed_dims}" \
        || { echo "${RED}ERROR: failed to apply the ${OPENSEARCH_SECRET_NAME} Secret.${NC}"; exit 1; }

    echo "${CYAN}      Installing session TTL reaper CronJob (retention ${ttl_hours}h)...${NC}"
    _opensearch_apply_ttl_cronjob "${ttl_hours}" \
        || echo "${YELLOW}WARN: TTL CronJob was not installed; expired session documents will accumulate.${NC}"

    # ---- 6/6 seed the sample knowledge corpus ------------------------------
    if [[ "${seed}" == "yes" || "${seed}" == "on" ]]; then
        echo "${CYAN}[6/6] Seeding sample knowledge corpus (embeddings via GenAI Gateway -> Bedrock)...${NC}"
        _opensearch_seed_sample_data "${embed_model}" "${embed_dims}" \
            || echo "${YELLOW}WARN: sample data seeding did not complete; the RAG demo query will return no hits.${NC}"
    else
        echo "${CYAN}[6/6] Skipping sample data seeding (opensearch_seed_sample_data=off).${NC}"
    fi

    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Amazon OpenSearch Service memory backend bound successfully!${NC}"
    echo "${GREEN}  Domain      : ${domain_name}${NC}"
    echo "${GREEN}  Endpoint    : ${_os_url}${NC}"
    echo "${GREEN}  Short-term  : ${OPENSEARCH_SHORT_TERM_INDEX} (expires_at + TTL CronJob, ${ttl_hours}h)${NC}"
    echo "${GREEN}  Long-term   : ${OPENSEARCH_KNOWLEDGE_INDEX} (k-NN dim ${embed_dims} + BM25)${NC}"
    echo "${GREEN}  Hybrid RAG  : search_pipeline=${OPENSEARCH_HYBRID_PIPELINE}${NC}"
    echo "${GREEN}  URL secret  : ${OPENSEARCH_SECRET_NAME} in namespace ${OPENSEARCH_NAMESPACE} (key: OPENSEARCH_URL)${NC}"
    echo "${GREEN}  NOTE        : read session state with GET /<index>/_doc/<id>, not _search${NC}"
    echo "${GREEN}                (_search is ~1s eventually consistent)${NC}"
    echo "${GREEN}============================================================${NC}"
}

# ---------------------------------------------------------------------------
# _opensearch_apply_secret <host> <url> <user> <pass> <embed_model> <embed_dims>
#
# Builds and applies the credentials Secret. Values are base64-encoded into a
# heredoc so no secret material appears in any process's argument list.
# ---------------------------------------------------------------------------
_opensearch_apply_secret() {
    local host="$1" url="$2" user="$3" pass="$4" model="$5" dims="$6"

    # base64 -w0 is GNU-only; fall back to folding output for BSD/busybox coreutils.
    _b64() { printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'; }

    # The userinfo half of OPENSEARCH_URL must be percent-encoded: a generated
    # password containing '@' or '/' would otherwise split the authority and
    # silently produce a URL pointing at the wrong host. Consumers that prefer
    # not to parse a URL should use OPENSEARCH_ENDPOINT + USERNAME + PASSWORD.
    local user_enc pass_enc
    user_enc=$(jq -rn --arg s "${user}" '$s|@uri')
    pass_enc=$(jq -rn --arg s "${pass}" '$s|@uri')

    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${OPENSEARCH_SECRET_NAME}
  namespace: ${OPENSEARCH_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: enterprise-agent-toolkit
    app.kubernetes.io/component: memory-backend
type: Opaque
data:
  OPENSEARCH_HOST: $(_b64 "${host}")
  OPENSEARCH_PORT: $(_b64 "443")
  OPENSEARCH_USE_SSL: $(_b64 "true")
  OPENSEARCH_ENDPOINT: $(_b64 "${url}")
  OPENSEARCH_URL: $(_b64 "https://${user_enc}:${pass_enc}@${host}")
  OPENSEARCH_USERNAME: $(_b64 "${user}")
  OPENSEARCH_PASSWORD: $(_b64 "${pass}")
  OPENSEARCH_SHORT_TERM_INDEX: $(_b64 "${OPENSEARCH_SHORT_TERM_INDEX}")
  OPENSEARCH_KNOWLEDGE_INDEX: $(_b64 "${OPENSEARCH_KNOWLEDGE_INDEX}")
  OPENSEARCH_HYBRID_PIPELINE: $(_b64 "${OPENSEARCH_HYBRID_PIPELINE}")
  OPENSEARCH_EMBED_MODEL: $(_b64 "${model}")
  OPENSEARCH_EMBED_DIMS: $(_b64 "${dims}")
EOF
}

# ---------------------------------------------------------------------------
# _opensearch_apply_ttl_cronjob <ttl_hours>
#
# Redis expired keys natively; OpenSearch has no per-document TTL and ISM works
# on whole indices. This CronJob reaps documents whose expires_at has passed,
# and also sweeps documents that predate the retention window but were written
# without an expires_at stamp, so a caller that forgets to set it still gets
# bounded growth.
#
# It reads the domain URL from the Secret published above rather than baking
# credentials into the manifest.
# ---------------------------------------------------------------------------
_opensearch_apply_ttl_cronjob() {
    local ttl_hours="$1"

    kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${OPENSEARCH_TTL_CRONJOB}
  namespace: ${OPENSEARCH_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: enterprise-agent-toolkit
    app.kubernetes.io/component: memory-backend
spec:
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: reaper
              image: curlimages/curl:8.11.0
              env:
                - name: OPENSEARCH_ENDPOINT
                  valueFrom:
                    secretKeyRef: { name: ${OPENSEARCH_SECRET_NAME}, key: OPENSEARCH_ENDPOINT }
                - name: OPENSEARCH_USERNAME
                  valueFrom:
                    secretKeyRef: { name: ${OPENSEARCH_SECRET_NAME}, key: OPENSEARCH_USERNAME }
                - name: OPENSEARCH_PASSWORD
                  valueFrom:
                    secretKeyRef: { name: ${OPENSEARCH_SECRET_NAME}, key: OPENSEARCH_PASSWORD }
                - name: INDEX
                  valueFrom:
                    secretKeyRef: { name: ${OPENSEARCH_SECRET_NAME}, key: OPENSEARCH_SHORT_TERM_INDEX }
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  # Two clauses, deliberately: documents that carry expires_at are
                  # reaped on their own stamp, and documents written without one
                  # fall back to the retention window so growth stays bounded.
                  curl -sS -f -u "\$OPENSEARCH_USERNAME:\$OPENSEARCH_PASSWORD" \\
                    -X POST "\$OPENSEARCH_ENDPOINT/\$INDEX/_delete_by_query?conflicts=proceed" \\
                    -H 'Content-Type: application/json' \\
                    -d '{
                          "query": {
                            "bool": {
                              "should": [
                                { "range": { "expires_at": { "lt": "now" } } },
                                { "bool": {
                                    "must_not": { "exists": { "field": "expires_at" } },
                                    "must": { "range": { "created_at": { "lt": "now-${ttl_hours}h" } } }
                                } }
                              ],
                              "minimum_should_match": 1
                            }
                          }
                        }'
              resources:
                requests: { cpu: 10m, memory: 32Mi }
                limits:   { cpu: 200m, memory: 128Mi }
EOF
}

# ---------------------------------------------------------------------------
# _opensearch_seed_sample_data <embed_model> <embed_dims>
#
# Embeds core/inventory/sample-knowledge.jsonl through the GenAI Gateway (which
# routes to Amazon Bedrock) and bulk-indexes the result into the knowledge
# index. This is what makes the out-of-the-box RAG demo answerable, and doubles
# as an end-to-end proof of gateway -> Bedrock embeddings -> OpenSearch.
#
# Returns non-zero on failure; the caller treats seeding as non-fatal because a
# deployed-but-unseeded stack is still usable.
# ---------------------------------------------------------------------------
_opensearch_seed_sample_data() {
    local embed_model="$1" embed_dims="$2"
    local corpus="${SCRIPT_DIR}/inventory/sample-knowledge.jsonl"

    if [[ ! -f "${corpus}" ]]; then
        echo "${YELLOW}      no corpus at ${corpus} - nothing to seed${NC}"
        return 0
    fi

    # Skip if already populated, so a redeploy does not duplicate documents.
    local count_resp existing
    count_resp=$(_opensearch_api GET "/${OPENSEARCH_KNOWLEDGE_INDEX}/_count")
    existing=$(jq -r '.count // 0' <<<"${count_resp}" 2>/dev/null || echo 0)
    if [[ "${existing}" =~ ^[0-9]+$ ]] && (( existing > 0 )); then
        echo "${YELLOW}      ${OPENSEARCH_KNOWLEDGE_INDEX} already holds ${existing} documents - skipping seed${NC}"
        return 0
    fi

    # The gateway master key lives in the vault generated by setup-env.sh.
    local vault_file="${SCRIPT_DIR}/inventory/metadata/vault.yml"
    local master_key=""
    if [[ -f "${vault_file}" ]]; then
        master_key=$(grep -E '^litellm_master_key:' "${vault_file}" \
            | awk '{print $2}' | tr -d '"'"'"'' || true)
    fi
    if [[ -z "${master_key}" ]]; then
        echo "${YELLOW}      litellm_master_key not found in vault.yml - cannot embed, skipping seed${NC}"
        return 1
    fi

    local gw_ns="genai-gateway"
    local gw_deploy="deploy/genai-gateway-deployment"
    if ! kubectl -n "${gw_ns}" get "${gw_deploy}" &>/dev/null; then
        echo "${YELLOW}      ${gw_deploy} not found in ${gw_ns} - cannot embed, skipping seed${NC}"
        return 1
    fi

    # The LiteLLM image ships no curl, so 'kubectl exec -- curl' fails with
    # "executable file not found in $PATH" and every embedding silently returns
    # nothing. Port-forward the service and use this host's curl instead.
    local gw_port=14001
    local gw_url="http://127.0.0.1:${gw_port}"
    kubectl -n "${gw_ns}" port-forward svc/genai-gateway-service "${gw_port}:4000" \
        >/tmp/.eat-seed-portforward.log 2>&1 &
    local gw_pf_pid=$!
    local gw_up=0 i
    for i in $(seq 1 30); do
        kill -0 "${gw_pf_pid}" 2>/dev/null || break
        if [[ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
                  -H "Authorization: Bearer ${master_key}" \
                  "${gw_url}/v1/models" 2>/dev/null)" == "200" ]]; then
            gw_up=1; break
        fi
        sleep 2
    done
    if (( gw_up == 0 )); then
        kill "${gw_pf_pid}" 2>/dev/null || true
        echo "${YELLOW}      gateway admin API not reachable on ${gw_url} - skipping seed${NC}"
        return 1
    fi

    # Seeding runs inside the toolkit deploy, before anything else registers
    # models, so the embedding model has to be registered here or every embed
    # call returns "model not found" and the corpus lands empty.
    if ! curl -sS --max-time 10 "${gw_url}/v1/models" \
            -H "Authorization: Bearer ${master_key}" 2>/dev/null \
            | jq -e --arg m "${embed_model}" '.data[]? | select(.id == $m)' >/dev/null 2>&1; then
        echo "${CYAN}      registering ${embed_model} with the gateway${NC}"
        curl -sS --max-time 30 -X POST "${gw_url}/model/new" \
            -H "Authorization: Bearer ${master_key}" \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn --arg m "${embed_model}" --arg r "${region}" \
                  '{model_name:$m, litellm_params:{model:("bedrock/"+$m), aws_region_name:$r}, model_info:{mode:"embedding"}}')" \
            >/dev/null 2>&1 \
            || echo "${YELLOW}      WARN: could not register ${embed_model}${NC}"
    fi

    local bulk_file
    bulk_file=$(mktemp)
    local seeded=0 failed=0 line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        local text title doc_id
        text=$(jq -r '.text' <<<"${line}")
        title=$(jq -r '.title // ""' <<<"${line}")
        doc_id=$(jq -r '.doc_id // empty' <<<"${line}")
        [[ -z "${doc_id}" ]] && doc_id="seed-$(( seeded + failed + 1 ))"

        # Embed through the gateway so the call uses the gateway's own Bedrock
        # credentials and network path.
        local embed_req embed_resp vector
        embed_req=$(jq -cn --arg m "${embed_model}" --arg i "${text}" '{model:$m, input:$i}')
        embed_resp=$(curl -sS --max-time 60 -X POST "${gw_url}/v1/embeddings" \
                -H "Authorization: Bearer ${master_key}" \
                -H 'Content-Type: application/json' \
                -d "${embed_req}" 2>/dev/null)
        vector=$(jq -c '.data[0].embedding // empty' <<<"${embed_resp}" 2>/dev/null)

        if [[ -z "${vector}" ]]; then
            echo "${YELLOW}      embedding failed for '${doc_id}': $(head -c 200 <<<"${embed_resp}")${NC}"
            failed=$(( failed + 1 ))
            continue
        fi
        # Guard the dimension: a mismatch means opensearch_embed_model and the
        # model actually registered in the gateway disagree, and every bulk
        # index would fail with an opaque mapper error.
        local got_dims
        got_dims=$(jq 'length' <<<"${vector}")
        if [[ "${got_dims}" != "${embed_dims}" ]]; then
            echo "${RED}      ERROR: ${embed_model} returned ${got_dims} dimensions but the index expects ${embed_dims}.${NC}"
            echo "${RED}             Fix opensearch_embed_model in agentic-config.cfg and recreate${NC}"
            echo "${RED}             the ${OPENSEARCH_KNOWLEDGE_INDEX} index (k-NN dimension is immutable).${NC}"
            rm -f "${bulk_file}"
            kill "${gw_pf_pid}" 2>/dev/null || true
            return 1
        fi

        jq -cn --arg id "${doc_id}" --arg idx "${OPENSEARCH_KNOWLEDGE_INDEX}" \
            '{index:{_index:$idx,_id:$id}}' >> "${bulk_file}"
        jq -cn --arg id "${doc_id}" --arg t "${title}" --arg x "${text}" \
               --argjson v "${vector}" \
            '{doc_id:$id, title:$t, text:$x, source:"sample-knowledge", embedding:$v}' \
            >> "${bulk_file}"
        seeded=$(( seeded + 1 ))
    done < "${corpus}"

    kill "${gw_pf_pid}" 2>/dev/null || true

    if (( seeded == 0 )); then
        echo "${YELLOW}      no documents could be embedded - skipping bulk index${NC}"
        rm -f "${bulk_file}"
        return 1
    fi

    # _bulk requires a trailing newline; without it the final action is dropped.
    printf '\n' >> "${bulk_file}"
    local bulk_resp bulk_code bulk_body
    bulk_resp=$(curl -sS -u "${_os_user}:${_os_pass}" -X POST \
        -H 'Content-Type: application/x-ndjson' \
        --data-binary "@${bulk_file}" \
        -w '\n%{http_code}' --max-time 180 \
        "${_os_url}/_bulk?refresh=wait_for" 2>&1)
    rm -f "${bulk_file}"
    bulk_code=$(printf '%s' "${bulk_resp}" | tail -n1)
    bulk_body=$(printf '%s' "${bulk_resp}" | sed '$d')

    if [[ "${bulk_code}" != "200" ]]; then
        echo "${RED}      ERROR: bulk index returned HTTP ${bulk_code}: $(head -c 300 <<<"${bulk_body}")${NC}"
        return 1
    fi
    if [[ "$(jq -r '.errors' <<<"${bulk_body}" 2>/dev/null)" == "true" ]]; then
        echo "${RED}      ERROR: bulk index reported per-document errors:${NC}"
        jq -r '[.items[].index | select(.error) | .error.reason] | unique | .[]' \
            <<<"${bulk_body}" 2>/dev/null | head -5
        return 1
    fi

    echo "${GREEN}      seeded ${seeded} documents into ${OPENSEARCH_KNOWLEDGE_INDEX}${NC}"
    (( failed > 0 )) && echo "${YELLOW}      ${failed} document(s) could not be embedded${NC}"
    return 0
}
