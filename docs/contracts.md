<!-- Sanitized copy of the VisionKB contracts (site paths, group and account names replaced by placeholders). -->

# Contracts between VisionKB repositories (v0.8, 2026-11-09)

Every repo builds against this file. Change it here first (bump the version line), then in code.
Biolink names are given in KGX form (snake_case slots, `biolink:` CURIEs). Verified present in Biolink 4.4.6:
`study result` class; slots `has_study_results`, `anatomical_context_qualifier`, `species_context_qualifier`,
`stage_qualifier`, `quantifier_qualifier`, `supporting_data_set`, `evidence_count`, `has_evidence`,
`publications` (multivalued association slot; checked 2026-11-09 after a reviewer flagged it as unverified), `knowledge_level`, `agent_type`;
predicates `expressed_in`, `gene_associated_with_condition`, `genetically_associated_with` (**deprecated** in 4.4.6 — do not emit; use
`gene_associated_with_condition`), `has_phenotype`, `causes`, `subclass_of`, `part_of`.

## 1. Data locations (the HPC filesystem, never in git)

Two roots:
- `$VISIONKB_DATA_ROOT` = `/path/to/visionkb`: **final, group-shared** outputs (SOMA stores, summaries,
  registry records, immutable KG releases, HPC-side config). Readable by the lab group.
- `$VISIONKB_WORK_DIR` = `/path/to/visionkb-work` (intermediate data mirror): **intermediate,
  regenerable** data: conversion scratch, KG build working files, Slurm logs, test fixtures, Neo4j/PostgreSQL runtime
  state (database files are rebuilt from a release). One subfolder per repo: `$VISIONKB_WORK_DIR/<repo>/…`.

```
$VISIONKB_WORK_DIR/
├── visionkb-atlas/<dataset_id>/<atlas_version>/   # tmp SOMA writes, logs, profiling (peak RSS)
├── visionkb-kg/build/<kg_release>/                # kgx per source, merged, staged downloads, logs
├── visionkb-api/fixtures/                         # tiny fixture release for tests
└── visionkb-deploy/<instance>/                    # neo4j data/logs, postgres data, api logs, pulled .sif images
```

### Final layout (`$VISIONKB_DATA_ROOT`)

```
$VISIONKB_DATA_ROOT/
├── config/
│   ├── sources.yaml                 # real input paths (HECA h5ad, retigene, HGNC, ontologies); copy of each repo's sources.example.yaml
│   └── atlases.yaml                 # per-atlas obs column map (see §2) — the HPC filesystem copy of visionkb-atlas/config/atlases.example.yaml
├── atlas/<dataset_id>/<atlas_version>/          # written by visionkb-atlas
│   ├── soma/                        # TileDB-SOMA Experiment (measurement "RNA"; X layers "counts" [, "data"])
│   ├── source.json                  # h5ad path, size, mtime, sha256 (or size+mtime if hashing disabled), n_obs, n_var, tool versions
│   ├── validation.json              # round-trip checks h5ad vs SOMA (n_obs, n_var, nnz, obs columns, sum of counts for sampled rows)
│   ├── summaries/expr_summary.parquet   # §3
│   ├── summaries/groups.parquet     # one row per group: level, group_label, n_cells, n_donors, mapping to CL / CellState
│   └── registry.json                # §4 dataset registry record
└── kg/releases/<kg_release>/        # immutable release (visionkb-kg output; visionkb-deploy/visionkb-api input)
    ├── RELEASE                      # one line: the release id
    ├── manifest.json                # §6
    ├── kgx/nodes.jsonl, kgx/edges.jsonl          # merged KGX (exchange format)
    ├── neo4j-import/                # §5
    ├── summaries/expr_summary.parquet            # concatenation of all atlas expr_summary files in this release
    ├── registry/datasets.jsonl      # §4, one record per dataset
    └── validation/report.json, validation/report.md
```

Directory and file names never contain ':' (breaks scp/rsync host:path parsing and k8s names): folders use the slug, e.g.
`atlas/ds-hrca-snrna/heca-2026.05/`, while files keep the full CURIE `visionkb:ds-hrca-snrna` as `dataset_id`.
IDs: `dataset_id` = `visionkb:ds-<slug>` with slug like `hrca-snrna`, `iris-scrna`; `atlas_version` like `heca-2026.05`
(the HECA h5ad build) ; `kg_release` = `visionkb-YYYY.MM.N` (first: `visionkb-2026.11.0`).

### Release bundle (portable; D15-D17)

`visionkb-kg pack <kg_release>` writes `$VISIONKB_DATA_ROOT/kg/bundles/<kg_release>.tar` and `<kg_release>.tar.sha256`. The tar holds the
release folder above with **relative paths only**; `manifest.json` lists every file with sha256. `visionkb-kg verify <bundle>` (and the deploy
tooling) checks the outer sha256 and every manifest checksum. Everything the API needs is inside the bundle (neo4j-import/, summaries/,
registry/, manifest.json); nothing at run time may reference the HPC filesystem. Registry `h5ad_path`/`soma_uri`/`bind.path` are the HPC cluster-side metadata only.
Environments: dev/test on the HPC cluster (bundle unpacked from the HPC filesystem); production on the Eye server k8s (bundle copied in or fetched by URL; no the HPC filesystem).

## 2. Atlas column map (`atlases.yaml`)

Per atlas: `dataset_id, title, h5ad (path), species (NCBITaxon:9606), tissue (UBERON list), assay (EFO), counts_source
(X | layers/<name> | raw/X), donor_col, sample_col, majorclass_col, celltype_col (optional), region_col (optional),
label_maps (optional)`. obs schemas differ between atlases (e.g. donor column `donorid` / `donor` / `Donor`; cell type
`majorclass` / `cell_type` / `celltype` / `subclass`), so nothing is hard-coded.

## 3. `expr_summary.parquet` (one row per gene × group; all genes, no threshold)

| column | type | meaning |
|---|---|---|
| dataset_id, atlas_version | str | |
| level | str | `majorclass` \| `celltype` \| `region_majorclass` |
| group_label | str | label as in the atlas (`Rod`, `AC`, …); for `region_majorclass`: `<region>|<majorclass>` |
| cell_type_id | str | CL CURIE for exact/broad crosswalk matches, else `visionkb:cs-<dataset-slug>-<label-slug>` (CellState) |
| region | str \| null | region label (e.g. `fovea`) when level = `region_majorclass` |
| gene_id | str | `HGNC:<n>` when resolvable, else `ENSEMBL:<ENSG…>`, else `visionkb:gene-<symbol>` (flagged) |
| gene_symbol | str | approved symbol (HGNC) after resolution; `var_symbol` keeps the atlas name |
| n_cells | int | cells in the group |
| n_donors | int | donors in the group |
| n_expressing | int | cells with count > 0 |
| pct_expressing | float | n_expressing / n_cells (0–1) |
| mean_log1p_cp10k | float | mean over all group cells of log1p(count / total_counts × 1e4) |
| pseudobulk_cp10k | float | sum(counts gene) / sum(total_counts) × 1e4 over the group |
| n_donors_expressing | int | donors in which ≥ 10 % of that donor's group cells express the gene |

Counts: raw integer counts (verified per atlas; `counts_source` in `atlases.yaml`). Computed by streaming SOMA in obs blocks; never densify a full matrix.

## 4. Dataset registry record (`registry.json` / `datasets.jsonl`; also a `Dataset` node in Neo4j)

`id, version (atlas_version), title, species, tissue[], assay, disease (MONDO, optional), stage, n_cells, n_donors,
n_samples, levels[], cell_types[] (CL / CellState ids), format ("h5ad"|"soma"), h5ad_path, soma_uri, checksum,
access_level ("public"|"lab"|"restricted"), license, citation (DOI, optional), kg_release (set when released),
bind: {path, name, role}` — `bind.path` = h5ad path (what AiScientist binds today), `role` default `reference`.
HECA atlases: `access_level = "lab"` until published.

## 5. Neo4j layout (`neo4j-import/`, for `neo4j-admin database import full`)

- Node labels: the Biolink category class names without prefix, PascalCase, every node also `NamedThing`
  (e.g. `:Gene:NamedThing`, `:Cell:AnatomicalEntity:NamedThing`, `:StudyResult:NamedThing`, `:Dataset:NamedThing`);
  VisionKB classes the same way (`:CellState:Cell:…`).
- Node properties: `id` (CURIE, unique), `name`, `category` (string[] of `biolink:` CURIEs), `symbol`, `synonym` (string[]),
  `xref` (string[]), `description`, `in_taxon`, `provided_by` (string[]), class-specific fields.
- Relationship type = Biolink predicate without prefix (`expressed_in`, `subclass_of`, `gene_associated_with_condition`, …).
  Relationship properties: `id` (deterministic: sha1 of subject|predicate|object|sorted qualifiers, prefixed `visionkb:e-`),
  `predicate` (`biolink:` CURIE), qualifiers (`anatomical_context_qualifier`, `species_context_qualifier`, `stage_qualifier`,
  `object_aspect_qualifier`, `object_direction_qualifier`, `qualified_predicate`, `subject_form_or_variant_qualifier`, …),
  `knowledge_level`, `agent_type`, `primary_knowledge_source` (infores), `aggregator_knowledge_source` (string[]),
  `publications` (string[]), `has_study_results` (string[] of StudyResult ids), `evidence_count`,
  `status` (`curated`|`proposed`|`rejected`), `visibility` (`public`|`lab`|`owner`), `kg_release`, and summary
  properties for expression edges: `max_pct_expressing`, `max_mean_log1p_cp10k`, `n_datasets`.
- Evidence: `(:StudyResult {id, edge_id, dataset_id, atlas_version, level, group_label, n_cells, n_donors, pct_expressing,
  mean_log1p_cp10k, pseudobulk_cp10k, n_donors_expressing, method})-[:supporting_data_set]->(:Dataset)`;
  literature evidence as `StudyResult` with `pmid`, `supporting_text` (short, ≤ 300 chars), `grade`, `review_note`.
  `edge_id` and `id` are indexed so `get_evidence(edge_id)` is one lookup.
- Files: `nodes_<Label>.csv` and `rels_<type>.csv` with neo4j-admin headers (`id:ID`, `:LABEL`, `:START_ID`, `:END_ID`, `:TYPE`,
  arrays `prop:string[]` with `;` delimiter), plus `import.args` listing them and `post_import.cypher` (constraints, full-text index
  `entity_search` on name/symbol/synonym, indexes on `StudyResult.edge_id`).

## 6. `manifest.json`

`kg_release, created_utc, biolink_version ("4.4.6"), schema_version (visionkb LinkML), code: {visionkb-kg: version+git sha,
visionkb-atlas: version+git sha}, sources: [{name, version/date, path_or_url, sha256, license, infores}], atlases:
[{dataset_id, atlas_version, summary_sha256}], counts: {nodes_by_category, edges_by_predicate, study_results},
validation: {status, n_errors, n_warnings}, files: [{path, bytes, sha256}]`.

## 7. Knowledge sources (infores) and epistemic fields

| Source | primary_knowledge_source | knowledge_level | agent_type |
|---|---|---|---|
| HECA atlas expression | `infores:visionkb-heca` | `observation` | `data_analysis_pipeline` |
| retigene curated HI review | `infores:visionkb-retigene` | `knowledge_assertion` | `manual_validation_of_automated_agent` |
| Ontology hierarchy (CL, UBERON, MONDO, HPO) | `infores:cl`, `infores:uberon`, `infores:mondo`, `infores:hpo` | `knowledge_assertion` | `manual_agent` |
| HGNC genes | `infores:hgnc` | — (nodes) | — |
| AiScientist proposals | `infores:visionkb-aiscientist` | `statistical_association` / `observation` | `data_analysis_pipeline` |

`infores:visionkb-*` are local, not yet registered.

## 8. API (visionkb-api, base path `/v1`, JSON)

Envelope for every response: `{"status": "ok"|"error", "kg_release": str, "data": ..., "page": {"limit", "offset", "total"} | null,
"warnings": [str], "error": {"code", "message"} | null}`. Default limit 50, max 200. Errors never fall back to invented data.

| Method + path | Design function | Params | `data` |
|---|---|---|---|
| GET `/v1/health` | — | — | `{neo4j, summaries, postgres, release}` (no auth) |
| GET `/v1/release` | — | — | manifest subset (§6) |
| GET `/v1/entities/search` | `search_entities` | `q`, `category?`, `limit` | `[{id, name, category, symbol, synonyms, match ("exact_id"|"exact_symbol"|"synonym"|"fulltext"), score}]` |
| GET `/v1/entities/{curie}` | — | — | node + degree by predicate |
| GET `/v1/relationships` | `get_relationships` | `subject?`, `object?`, `predicate?`, `object_category?`, `knowledge_level?`, `species?`, `limit`, `offset` | `[{edge_id, subject{id,name,category}, predicate, object{…}, qualifiers{}, knowledge_level, agent_type, primary_knowledge_source, publications[≤5], evidence_count, status}]` |
| GET `/v1/evidence/{edge_id}` | `get_supporting_publications` | `limit` | `{edge, study_results[], publications[]}` |
| GET `/v1/gene-sets` | `get_gene_set` | `entity` (CL/CellState/MONDO/HP CURIE), `kind` (`expressed`\|`disease_genes`), `dataset?`, `min_pct?`, `limit` | `[{gene_id, symbol, score, evidence}]` |
| GET `/v1/atlas/expression` | `query_expression` | `genes` (ids or symbols, ≤ 20), `dataset?`, `level` (default `majorclass`), `cell_type?`, `sort` (`pseudobulk_cp10k`), `limit` | rows of §3 + `dataset_version` |
| GET `/v1/datasets` | `find_datasets` | `entities?` (CURIEs), `species?`, `tissue?`, `assay?`, `disease?`, `limit` | `[{…registry record §4, score, matched}]` |
| POST `/v1/proposals` | write-back | KGX-style edge + evidence + `run_id`, `visibility` | `{proposal_id, status:"proposed"}` (token scope `proposals:write`) |
| GET `/v1/proposals` | curation | `status?`, `limit` | proposals (scope `proposals:read`) |

`compare_cell_states` and `get_perturbation_results` from the design are deferred (no DE / perturbation data in v0.1); not exposed.
Auth: bearer token; tokens in a file (`VISIONKB_API_TOKENS_FILE`, lines `token<TAB>scopes`), scopes `read`, `proposals:read`, `proposals:write`.

## 9. Environment variables

| Var | Used by | Meaning |
|---|---|---|
| `VISIONKB_DATA_ROOT` | atlas, kg, deploy | final data root (§1) |
| `VISIONKB_WORK_DIR` | atlas, kg, api tests, deploy | intermediate data root (§1), intermediate dir |
| `VISIONKB_KG_RELEASE` | api, deploy | release id to serve / load |
| `VISIONKB_RELEASE_DIR` | api | `$VISIONKB_DATA_ROOT/kg/releases/$VISIONKB_KG_RELEASE` (mounted read-only) |
| `NEO4J_URI`, `NEO4J_USER`, `NEO4J_PASSWORD_FILE` | api, deploy | Bolt connection (password from a file, never in env/argv logs) |
| `VISIONKB_PG_DSN_FILE` | api, deploy | PostgreSQL DSN in a file (proposals) |
| `VISIONKB_API_TOKENS_FILE` | api | bearer tokens |
| `VISIONKB_API_HOST`, `VISIONKB_API_PORT` | api, deploy | bind (default `127.0.0.1:8770`) |
| `VISIONKB_MAX_ROWS` | api | hard cap (200) |
| `VISIONKB_API_URL`, `VISIONKB_API_TOKEN_FILE` | MCP server, skill | client side |

## 10. Pinned versions (v0.1)

Biolink 4.4.6; linkml 1.12.x; kgx 2.8.x; bmt 1.5.x; tiledbsoma 2.3.x; anndata 0.13.x; Python 3.12/3.13;
Neo4j `neo4j:2026.10.1-community` (Docker Hub; Python driver `neo4j` 6.x); PostgreSQL `postgres:17.11`;
FastAPI 0.16x; DuckDB 2.0.x. Repos and images use semantic versions; KG releases use `visionkb-YYYY.MM.N`.
`visionkb-deploy/versions.env` pins image tags (by digest once published) and the KG release to serve.

## 11. Changes verified by the API track (v0.5, 2026-11-09; Neo4j 2026.10.1, Biolink 4.4.6)

- §5 `import.args`: file paths must be `./nodes_X.csv` (bare names are rejected by neo4j-admin 2026.10); run inside `neo4j-import/` with `@import.args`.
- §5 `post_import.cypher`: also `CREATE INDEX rel_id_<type> FOR ()-[r:<type>]-() ON (r.id)` for every relationship type, and
  `CREATE INDEX gene_symbol FOR (n:Gene) ON (n.symbol)`. Full-text queries use Cypher 25 `SEARCH … FULLTEXT INDEX entity_search`
  (`db.index.fulltext.queryNodes` is deprecated in 2026.10).
- §8 `/v1/relationships` requires `subject` or `object` (400 `missing_anchor`); `offset` on all list endpoints; `/v1/gene-sets` `kind` optional
  (inferred: `expressed` for CL/CellState, `disease_genes` for MONDO/HP), `descendants=true` follows `subclass_of` up to 3 hops; search
  `page.total` is null (ranked top-k); `/v1/health` returns 200 with degraded components listed in `warnings`.
- §8 proposals: statuses `proposed|accepted|rejected|withdrawn`; `knowledge_level` and `agent_type` required; `visibility` default `owner`;
  dedupe on (`run_id`, edge sha256); body ≤ 64 KiB.
- §9 optional env vars `NEO4J_DATABASE` (default `neo4j`), `VISIONKB_VERIFY_CHECKSUMS` (1 = sha256 every bundle file at startup).
- §10 Neo4j 2026.10 enables Fleet Manager, fleet discovery (UDP broadcast) and usage reports by default: every deployment sets
  `NEO4J_server_fleet__discovery_enabled=false`, `NEO4J_dbms_fleet__manager_enabled=false`, `NEO4J_dbms_usage__report_enabled=false`.

## 12. Changes verified by the Deploy track (v0.8, 2026-11-09)

- §1 bundle: the tar holds ONE top-level folder `<kg_release>/`; `<kg_release>.tar.sha256` is in `sha256sum` format (`<hex>  <name>`). Release ids
  always match `visionkb-YYYY.MM.N`, test fixtures included (use `visionkb-0000.MM.N`).
- §1 final layout adds `$VISIONKB_DATA_ROOT/backups/visionkb-deploy/<instance>/` — the PostgreSQL proposals DB is the only state NOT
  regenerable from a release; `visionkb backup` writes `pg_dump` files there.
- §5 `import.args`: one neo4j-admin option per line, `--nodes=[Labels=]file[,file]` / `--relationships=[TYPE=]file[,file]`, paths relative to
  `neo4j-import/`; `--overwrite-destination`, `--report-file`, `--additional-config`, `--expand-commands` are not allowed in a release
  (the loader adds its own). Each release is imported into a NEW store; rollback switches stores.
- §5/§9 Neo4j password is set per store at load time from `NEO4J_PASSWORD_FILE` (via an argfile, never argv); rotation = reload or ALTER USER per store.
- §8 add `GET /v1/ready` (no auth; 503 unless all components ok) for k8s readiness / compose healthchecks; `/v1/health` stays 200 + warnings.
  Tokens file: `token<TAB>scopes`, scopes comma- or whitespace-separated.
- §9 deploy variables: `VISIONKB_DEPLOY_DIR`, `VISIONKB_RELEASES_DIR`, `VISIONKB_BUNDLES_DIR`, `VISIONKB_BACKUP_DIR`, `VISIONKB_INSTANCE`,
  `VISIONKB_SERVICES`, `VISIONKB_BIND_ADDRESS`, `VISIONKB_NEO4J_BOLT_PORT`/`_HTTP_PORT`/`_LOAD_BOLT_PORT`, `VISIONKB_PG_HOST`/`_PG_PORT`,
  `VISIONKB_NEO4J_HEAP`/`_PAGECACHE`/`_READ_ONLY`, `VISIONKB_LOAD_HEAP`/`_PAGECACHE`, `VISIONKB_K8S_OVERLAY`, `VISIONKB_BUNDLE_URL_TEMPLATE`,
  `VISIONKB_APPTAINER_MODULE`, `VISIONKB_PYTHON` (see visionkb-deploy `config/visionkb.env.example`).
- §10 `versions.env` pins images as `name:tag@sha256:<index digest>`.

## 13. Manifest counts (v0.8, 2026-11-09)

`counts.nodes_total`, `counts.edges_total`, `counts.study_results` = distinct objects written to `neo4j-import/`. `counts.nodes_by_category` counts
each node once under its most specific category (e.g. `visionkb:CellState`, not also `biolink:Cell`) and sums to `nodes_total`;
`edges_by_predicate` sums to `edges_total`. `visionkb-deploy load-release` fails when neo4j-admin's imported totals differ from these.
Readiness: `GET /v1/ready` (visionkb-api ≥ 0.1.1) is the readiness endpoint everywhere; `/v1/health` is liveness. Pins: visionkb-api 0.1.1
`@sha256:5d956d0336763c9e12d2ee576ace9cc2f5ada02322cad9d7794e882ecb49ed7d`, visionkb-deploy 0.1.1.

## 14. Storage and load acceptance (v0.8, 2026-11-09)

- Neo4j stores and `neo4j-admin import` targets live on node-local or block storage, never on a network filesystem (BeeGFS/NFS/Lustre): stores on
  the HPC filesystem came back corrupted twice for `visionkb-2026.11.0` (4 nodes missing + 41 garbled ids; 25 nodes missing). the HPC cluster: `VISIONKB_STORE_DIR`
  (node-local, ephemeral) + persistent load records in `$VISIONKB_DEPLOY_DIR/<instance>/neo4j/loaded/<id>/`; `VISIONKB_ALLOW_NETWORK_STORE=1`
  overrides with a warning. PostgreSQL (proposals) stays on persistent storage with backups.
- Load acceptance = equality of the sorted node `id` set and the sorted relationship key set (`start|type|end|id`) between the store and the
  `neo4j-import` CSVs (visionkb-deploy ≥ 0.1.2), not counts only.
- Node CSV headers: `id:ID` only, unique property names per header (visionkb-kg ≥ 0.1.0, unit-tested).
- Publication: stage → bundle → verify copy → throwaway import + checks + `visionkb-deploy load-release` → rename into `kg/releases` and
  `kg/bundles` (`.sha256` last); invalid artifacts go to `kg/withdrawn/<release>-<HHMM>/` with `NOTE.md`.
