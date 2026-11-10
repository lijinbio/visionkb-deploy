# Kubernetes on the Eye server (production)

**Production = the Eye server's Kubernetes cluster. Dev/test = HPC3** ([hpc3.md](hpc3.md)). The Eye server cannot
read the HPC filesystem: releases arrive as bundles ([eyeserver.md](eyeserver.md#how-a-release-travels-from-the-hpc-filesystem-to-the-eye-server)).

Status of these manifests: both overlays render with kustomize and pass `kubeconform -strict` (CI); they have
**not been applied to a cluster yet**. Clients (AiScientist gateway: API URL, token file, MCP server, skills):
[aiscientist.md](aiscientist.md); an example NetworkPolicy for a gateway in another namespace is
`k8s/base/aiscientist-gateway-netpol.example.yaml`.

Bundle pin: each overlay's `release.env` carries `VISIONKB_KG_BUNDLE_SHA256`, the sha256 of the served release's
bundle. `bin/visionkb-k8s sync` writes it from versions.env when the overlay serves the pinned release; `switch`
and `rollback` set it to the pin for the pinned release and leave it empty for others. `upload-bundle` compares
it before contacting the cluster and again in the upload pod. The fetch-bundle Job compares the published
`.sha256` before downloading, then the downloaded bundle. If versions.env and release.env give different shas for
the same release, both stop and ask for `sync`. The key is part of ConfigMap `visionkb-release`: the first
apply after upgrading to 0.1.4 rolls neo4j and the API once.

## What gets deployed (`k8s/base`, namespace `visionkb`)

| Object | Notes |
|---|---|
| StatefulSet `neo4j` (1 replica, Community) | serves `/releases/<VISIONKB_KG_RELEASE>/data` on PVC `neo4j-releases`; read-only database; init container refuses a release that is not loaded; Service ClusterIP (7687 bolt, 7474 http) |
| StatefulSet `postgres` | proposals DB, PVC from volumeClaimTemplate; SCRAM auth; Service ClusterIP 5432 |
| Deployment `visionkb-api` (2 replicas) | image from `versions.env`; readiness `/v1/ready` (503 unless release, neo4j, summaries and postgres are ok), liveness `/v1/health`; non-root, read-only root fs, all capabilities dropped; requests/limits; reads the unpacked bundle read-only from PVC `visionkb-bundles` |
| Ingress `visionkb-api` | **the only exposed object**; host + TLS secret are placeholders; cert-manager annotation optional |
| NetworkPolicies | default deny ingress; neo4j only from API pods; postgres only from API and backup pods; API only from the ingress-controller namespace |
| CronJob `visionkb-backup` | nightly `pg_dump -Fc` onto PVC `visionkb-backups`, keeps 14 |
| ConfigMaps | `visionkb-settings` (memory, read-only flag), `visionkb-scripts` (loader + bundle.py), `visionkb-release` (overlay `release.env`; hash suffix: a change rolls neo4j and the API) |
| Secrets (not in kustomization) | `visionkb-neo4j`, `visionkb-postgres`, `visionkb-api`; mounted as files (`*_FILE`); template `secrets.example.yaml` |
| Job templates | `jobs/load-release.yaml` (init container verifies checksums and writes the expected node ids / relationship keys; the loader fails if the store differs), overlay `fetch-bundle.yaml`, `upload-pod.yaml`; rendered per release by `bin/visionkb-k8s` (Jobs are immutable) |

## Delivery mode: one setting

`VISIONKB_K8S_OVERLAY` (env or `--overlay`) selects the overlay, default `local-bundle`:

| Overlay | Bundle path into the cluster |
|---|---|
| `local-bundle` | the operator copies `<id>.tar` + `.sha256` onto the Eye server (scp, Globus, laptop hop); `bin/visionkb-k8s upload-bundle <tar>` checks the sha256 locally, starts a short-lived pod on `visionkb-bundles`, `kubectl cp`s the files in, runs `bundle.py unpack` (outer sha256 + every manifest checksum), deletes the pod, runs the load-release Job |
| `fetch-bundle` | `bin/visionkb-k8s fetch-bundle <id>` runs a Job that downloads `<url>/<id>.tar` and `.tar.sha256` over HTTPS (URL template `VISIONKB_BUNDLE_URL_TEMPLATE` in the overlay, `{release}` replaced; optional `Name: value` auth header from Secret `visionkb-bundle-auth`), verifies, unpacks, then runs the load-release Job |

Neither mode touches the HPC filesystem or SSH to HPC.

## Install

```bash
# 0. images and scripts in k8s/base match versions.env
bin/visionkb-k8s sync --check
# 1. secrets: generate files once (on any machine; keep them off git), DSN pointing at the in-cluster Service
VISIONKB_DEPLOY_DIR=/path/to/visionkb-k8s-state VISIONKB_PG_HOST=postgres VISIONKB_PG_PORT=5432 bin/visionkb init
bin/visionkb-k8s create-secrets --from /path/to/visionkb-k8s-state/default/secrets
# 2. set host, TLS secret, ingress class, StorageClass, ingress-controller namespace label in an overlay
#    (or kustomize edit / patches), then:
bin/visionkb-k8s apply
# 3. first release
bin/visionkb-k8s upload-bundle /path/to/bundles/visionkb-2026.11.0.tar    # or fetch-bundle visionkb-2026.11.0
bin/visionkb-k8s switch visionkb-2026.11.0     # skip if release.env already names it: then just wait for neo4j
bin/visionkb-k8s status
```

Until a release is loaded, the neo4j pod waits in its init container (`require-loaded-release`) and the API is
not ready; that is expected. Switching edits `k8s/overlays/<mode>/release.env` (current -> previous), applies, and
waits for the rollouts; `rollback` switches to `VISIONKB_PREVIOUS_RELEASE`. Keep the deployment's `release.env`
under version control on a deployment branch (or note it in the change log), since it is the record of what is served.

Storage: give `neo4j-releases` block storage (local disk or a block-device StorageClass), not an NFS-backed volume:
a Neo4j store written on a network filesystem came back corrupted on HPC3 ([operations.md](operations.md#neo4j-stores-on-network-filesystems-do-not)).

Access modes: all PVCs are `ReadWriteOnce`, which is per node; on the single-node Eye server every pod can mount
them. On a multi-node cluster use a ReadWriteMany StorageClass for `visionkb-bundles` and `neo4j-releases`
(the API replicas and the Jobs share them). Do not use `ReadWriteOncePod`.

## Ask the cluster admin (prerequisites)

1. **Ingress controller** in use (class name, e.g. `nginx`) and the label of its namespace (for the NetworkPolicy).
2. **NetworkPolicy enforcement**: does the CNI enforce NetworkPolicies? (If not, the isolation above is advisory.)
3. **cert-manager** installed? Which ClusterIssuer (ACME/campus CA)? Otherwise we bring a campus-issued certificate.
4. **StorageClass** for ~100 Gi (neo4j stores), ~50 Gi (bundles), ~10 Gi (postgres), ~10 Gi (backups); RWO or RWX;
   backup/snapshot policy for the postgres and backups volumes.
5. **Pod mounts**: confirm pods cannot (and need not) mount the HPC filesystem; any shared NFS is not required.
6. **Image pulls** from GHCR (`ghcr.io/lijinbio/visionkb-api`, public) and Docker Hub (`neo4j`, `postgres`, `python`):
   allowed egress, pull-through cache or mirror, Docker Hub rate limits, image policy (digest pinning is used).
7. **Resource quota** for the namespace: about 6 CPU / 16 Gi requests at steady state plus the load Job (up to 4 CPU / 12 Gi).
8. **Security policy**: Pod Security level of the namespace (manifests are non-root, no privilege escalation,
   capabilities dropped, seccomp RuntimeDefault; neo4j writes its config dir so its root fs is not read-only).
9. **Monitoring / logging**: Prometheus scraping, log collection, alert routing (who is paged if `/v1/health` fails).
10. **Egress** for the fetch-bundle Job to the bundle URL (if that mode is used).

## Domain, TLS and firewall

1. **DNS**: request a subdomain from the campus DNS / IT service (e.g. `visionkb.<department>.<campus-domain>`)
   pointing at the Eye server's ingress IP. Put it in the Ingress `host` and `tls.hosts`.
2. **Firewall / security review**: request an exception for TCP 443 (and 80 only if ACME HTTP-01 needs it) to the
   ingress IP, from the networks that need the API (campus, VPN, or specific gateway hosts). Expect a security
   review: describe the data exposed (below), authentication (bearer tokens), TLS, logging, and the owner.
3. **TLS**: either cert-manager (`cert-manager.io/cluster-issuer: <issuer>` annotation; the certificate lands in
   secret `visionkb-api-tls`), or a campus-issued certificate:
   `kubectl -n visionkb create secret tls visionkb-api-tls --cert=<fullchain.pem> --key=<key.pem>`; note the expiry.

## Data-exposure rule

- **Only the API is exposed.** Neo4j and PostgreSQL have ClusterIP Services only, no Ingress, and NetworkPolicies
  restrict them to API pods. Never add an Ingress, NodePort or LoadBalancer for them; use `kubectl port-forward`
  for admin work.
- The API serves only the release bundle, read-only, plus the proposals queue (separate token scopes).
- A release that contains **lab-access** data (unpublished HECA atlases: `access_level = "lab"`) may only be
  exposed with **bearer tokens** issued to lab members/services; `/v1/health` stays open and carries no data.
  If the API must be public without tokens, serve a **public-only release** (built without lab-access datasets).
- Bundles and backups stay inside the cluster volumes and approved machines; tokens are rotated by editing
  `api_tokens` and re-running `create-secrets` (then `kubectl -n visionkb rollout restart deployment/visionkb-api`).
