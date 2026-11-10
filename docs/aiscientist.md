# AiScientist gateway: using the KG on the Eye server

The AiScientist gateway reads the VisionKB knowledge graph through three released components, pinned in
[versions.env](../versions.env):

| Component | Pin (versions.env) | What the gateway does with it |
| --- | --- | --- |
| visionkb-api (served by this repo) | `VISIONKB_API_IMAGE` = `ghcr.io/lijinbio/visionkb-api:0.1.4@sha256:316e7854…` | HTTP `/v1`, bearer token with scope `read` |
| visionkb-kg MCP server ([aiscientist-mcp](https://github.com/lijinbio/aiscientist-mcp), tag `visionkb-kg-v0.0.1`) | `VISIONKB_MCP_IMAGE` = `ghcr.io/lijinbio/mcp-visionkb-kg:0.0.1@sha256:2425d313…` | runs it as a **stdio** child process: 8 read-only tools, one API GET per call |
| skills registry ([aiscientist-skills](https://github.com/lijinbio/aiscientist-skills)) | `VISIONKB_SKILLS_RELEASE=v0.2.1` | installs skill `knowledge-graph/answer-eye-questions-with-visionkb-kg` 0.0.1 |
| KG release | `VISIONKB_KG_RELEASE=visionkb-2026.11.0`, `VISIONKB_KG_BUNDLE_SHA256=0af5a709…` | what the API serves; the bundle is refused if its sha256 differs |

The MCP server and the skill are clients of the API; neither reads Neo4j, PostgreSQL or any files. The VisionKB
web page (service `web`, [hpc3.md](hpc3.md#web-home-page-service-web-opt-in), [k8s.md](k8s.md#web-home-page)) uses
the same two components internally: it runs `visionkb-kg-mcp` as a stdio child and the skill's `SKILL.md` as its
chat instructions, with each user's own Claude key entered in the browser. The gateway described here is a
separate client. Every result
carries `kg_release`; cite it (and `edge_id`) with any claim.

**Tested** below means run in the step-05 smoke test of this repo's release (HPC node, apptainer 1.4.5, the
stack serving a synthetic fixture release; see the "Tested" section). **Untested** means copied from the
component's own docs or from the manifests here, not run (there is no Docker and no Kubernetes cluster on
the test host).

## 1. API base URL

| Where the gateway runs | `VISIONKB_API_URL` | Status |
| --- | --- | --- |
| HPC node, same host as `bin/visionkb start` | `http://127.0.0.1:<VISIONKB_API_PORT>/v1` (default port 8770) | tested |
| Eye server, inside the cluster | `http://visionkb-api.visionkb.svc.cluster.local:8770/v1` (Service `visionkb-api`, port `http`, [k8s/base/api.yaml](../k8s/base/api.yaml)) | untested |
| Eye server, outside the cluster | `https://<ingress host>/v1` ([k8s/base/ingress.yaml](../k8s/base/ingress.yaml); host and TLS are set per deployment, see [k8s.md](k8s.md)) | untested |

In-cluster access needs a NetworkPolicy: the base policies only let the ingress controller reach the API. Use
[k8s/base/aiscientist-gateway-netpol.example.yaml](../k8s/base/aiscientist-gateway-netpol.example.yaml) with the
gateway's namespace and pod labels (`kubectl -n visionkb apply -f …`; untested, validated with kubeconform).
Going through the Ingress needs no extra policy. The URL may be given with or without `/v1`.

## 2. Read-scope token file

The gateway gets a **file** whose first non-comment (`#`), non-empty line is a bearer token with scope `read`
(`VISIONKB_API_TOKEN_FILE`). The token is never put on a command line or in an environment variable.

- HPC: `bin/visionkb init` writes `<deploy dir>/<instance>/secrets/api_token_read` (mode 600), a token that
  `api_tokens` lists with scope `read`. That file is the token file (tested).
- Eye server: the API's tokens are the `api_tokens` file in Secret `visionkb-api` (one `<token><TAB><scopes>` line
  per client, created by `bin/visionkb-k8s create-secrets --from DIR`, see [k8s.md](k8s.md)). Give the gateway
  `DIR/api_token_read`, or a dedicated line `<token><TAB>read` added to `api_tokens` (then re-run
  `create-secrets` and `kubectl -n visionkb rollout restart deployment/visionkb-api`). Mount the token into the
  gateway as a file from a Secret in the gateway's namespace, e.g. (untested)
  `kubectl -n <gateway namespace> create secret generic visionkb-kg-token --from-file=token=DIR/api_token_read`.

Without a token, only `/v1/health` and `/v1/ready` answer; the MCP tools then return `status: "error"` with
`error.code: "unauthorized"` (tested).

## 3. MCP server over stdio

Settings (environment of the server process): `VISIONKB_API_URL` (required), `VISIONKB_API_TOKEN_FILE`,
`VISIONKB_TIMEOUT_S` (seconds per HTTP request, default 30). The server speaks MCP on stdin/stdout, so it runs as a
child process of the gateway (one per session), not as a cluster Service.

apptainer (HPC, tested):

```bash
bin/visionkb pull mcp                                   # by digest, into the images dir; not started by visionkb
sif="$(bin/visionkb config | sed -n 's/^mcp_sif=//p')"
apptainer exec --containall --no-home --cleanenv --pwd / \
  -B /path/to/api_token_read:/run/secrets/visionkb_token:ro \
  --env VISIONKB_API_URL=http://127.0.0.1:8770/v1 --env VISIONKB_API_TOKEN_FILE=/run/secrets/visionkb_token \
  "$sif" visionkb-kg-mcp
# list the tools with the command-line client shipped in the same image (tested):
apptainer exec --containall --no-home --cleanenv --pwd / --env VISIONKB_API_URL=http://127.0.0.1:8770/v1 \
  "$sif" aiscientist-mcp --server visionkb-kg-mcp tools
```

Docker (Eye server or a Docker host; untested, from the image's Dockerfile with the pinned digest):

```bash
docker run -i --rm -e VISIONKB_API_URL=http://<api-host>:8770/v1 \
  -e VISIONKB_API_TOKEN_FILE=/run/secrets/visionkb_token -v /path/to/token:/run/secrets/visionkb_token:ro \
  ghcr.io/lijinbio/mcp-visionkb-kg:0.0.1@sha256:2425d3138146d48236dde432aa1094d6a824c0529da82359355b886777d549d4
```

Without containers (untested; from the package README): `pip install --no-deps` the `common` and `visionkb-kg`
packages of aiscientist-mcp at tag `visionkb-kg-v0.0.1` into the gateway's environment, then the command is
`visionkb-kg-mcp`. An MCP client registers it as a stdio server, e.g. (package README):
`{"type": "stdio", "command": "visionkb-kg-mcp", "env": {"VISIONKB_API_URL": "…", "VISIONKB_API_TOKEN_FILE": "…"}}`.
A gateway running in a Kubernetes pod needs the server inside its own container (the pip install, or the
image above as a base), because stdio does not cross pods.

Tools: `get_release`, `search_entities`, `get_entity`, `get_relationships`, `get_evidence`, `get_gene_set`,
`query_atlas_expression`, `find_datasets` (the package README lists arguments and returned fields). Errors are
results (`status: "error"`, `error.code`), not exceptions; nothing is retried or replaced with other data.

## 4. Skills release v0.2.1 (checksum-verified)

Pin the release tag (`VISIONKB_SKILLS_RELEASE`), never `main`. Every release ships `catalog.json`,
`aiscientist-skills-<version>.zip` and `SHA256SUMS` (tested):

```bash
rel=v0.2.1
base=https://github.com/lijinbio/aiscientist-skills/releases/download/$rel
mkdir -p "aiscientist-skills-$rel" && cd "aiscientist-skills-$rel"
curl -fsSL -O "$base/SHA256SUMS" -O "$base/catalog.json" -O "$base/aiscientist-skills-${rel#v}.zip"
sha256sum -c SHA256SUMS                                  # both lines must say OK
jq -r '.skills[] | select(.name == "answer-eye-questions-with-visionkb-kg") | "\(.path) \(.version)"' catalog.json
unzip -q "aiscientist-skills-${rel#v}.zip" 'skills/knowledge-graph/answer-eye-questions-with-visionkb-kg/*'
cp -R skills/knowledge-graph/answer-eye-questions-with-visionkb-kg /path/to/gateway/skills/
```

A skill is a folder; the gateway's skills directory is its own setting (the registry README's "Any agent, or by
hand" install). The skill needs network access to the API and `VISIONKB_API_TOKEN_FILE` (catalog
`requirements`); it uses the HTTP API (curl/jq or its `scripts/vkb_client.py`) or the MCP tools above.

## 5. Paging: the 24,000-character rule

- The API caps rows (`limit` at most 200) and each response at about **24,000 characters**. To stay within the
  size cap it may return **fewer rows than `limit`**, says so in `warnings`, and keeps `page.limit` unchanged.
- MCP list tools (`search_entities`, `get_relationships`, `get_evidence`, `get_gene_set`, `query_atlas_expression`,
  `find_datasets`) return a `paging` block `{returned, offset, limit, total, trimmed, next_offset, trimmed_lists,
  summary}`. For the next page pass **`offset = paging.next_offset`** (null on the last page). **Never step by
  `offset + limit`**: after a trimmed page that skips rows. Each MCP result stays within 24,000 characters.
- `search_entities` has no offset (ranked top-k): when it is trimmed, lower `limit` or narrow `q`.
- Direct HTTP clients: advance `offset` by the number of rows received (`len(data)`), never by `limit` (the skill's
  `kg.get_all` does this).

Tested: page 1 of `get_relationships(object=CL:0000604, limit=1)` returns `next_offset: 1`, and page 2 at that
offset returns a different edge; every MCP result in the smoke test was under 24,000 characters. The trimming
itself (a page cut by the size cap) needs a large release; it is covered by the MCP server's own tests and its
recorded run on `visionkb-2026.11.0` (package README), not by this repo's fixture smoke test.

## Tested

The step-05 smoke test (`tests/smoke/smoke-apptainer.sh`, section "AiScientist") pulls `VISIONKB_MCP_IMAGE` with
`bin/visionkb pull mcp`. It runs the server with the `apptainer exec` line above against the running stack, driven
by [tests/smoke/mcp_stdio_check.py](../tests/smoke/mcp_stdio_check.py), a stdlib MCP client. The client checks:
initialize, the 8 tools, `get_release` (= the served release, ready), `search_entities(q=RHO)` -> `HGNC:10012`,
paging by `next_offset`, the 24,000-character bound, and the `unauthorized` error without a token. The step's
`aiscientist` stage ran section 4 as written and the `aiscientist-mcp … tools` listing. Results are in the step's
README.
