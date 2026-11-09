"""Write a tiny, synthetic KG release that follows contracts v0.3 sections 1, 5 and 6.

Used by the tests and the smoke test. Identifiers are real (checked against HGNC and OLS on
2026-11-09); every numeric expression value is SYNTHETIC and means nothing.

    python3 tests/fixtures/make_fixture_release.py OUT_DIR visionkb-0000.01.1 [--variant 2]

writes OUT_DIR/<kg_release>/. Variant 2 adds one gene (PDE6B) and one expressed_in edge, so a
rollback between the two releases is visible in node and edge counts.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "src"))
from visionkb_deploy.bundle import check_release_id, sha256_file  # noqa: E402

DATASET = "visionkb:ds-fixture-retina"
ATLAS_VERSION = "fixture-0"
TAXON = "NCBITaxon:9606"
RETINA = "UBERON:0000966"
NOTE = "synthetic test fixture; values are not measurements"

# id, symbol, name (HGNC, verified 2026-11-09)
GENES = [
    ("HGNC:10012", "RHO", "rhodopsin", "ENSEMBL:ENSG00000163914"),
    ("HGNC:9937", "RCVRN", "recoverin", "ENSEMBL:ENSG00000109047"),
    ("HGNC:4393", "GNAT1", "G protein subunit alpha transducin 1", "ENSEMBL:ENSG00000114349"),
]
GENE_V2 = ("HGNC:8786", "PDE6B", "phosphodiesterase 6B", "ENSEMBL:ENSG00000133256")
# id, name (CL, verified 2026-11-09; CL:0000604 and CL:0000573 are subclasses of CL:0010009)
CELLS = [
    ("CL:0010009", "camera-type eye photoreceptor cell"),
    ("CL:0000604", "retinal rod cell"),
    ("CL:0000573", "retinal cone cell"),
]
SUBCLASS = [("CL:0000604", "CL:0010009"), ("CL:0000573", "CL:0010009")]
# gene, cell, group label, synthetic pct, synthetic mean, synthetic pseudobulk
EXPR = [
    ("HGNC:10012", "CL:0000604", "Rod", 0.95, 3.1, 410.0),
    ("HGNC:4393", "CL:0000604", "Rod", 0.80, 2.2, 120.0),
    ("HGNC:9937", "CL:0000604", "Rod", 0.70, 1.9, 90.0),
    ("HGNC:9937", "CL:0000573", "Cone", 0.60, 1.5, 70.0),
]
EXPR_V2 = [("HGNC:8786", "CL:0000604", "Rod", 0.50, 1.2, 40.0)]
N_CELLS = {"Rod": 200, "Cone": 50}


def edge_id(subject: str, predicate: str, obj: str, qualifiers: dict) -> str:
    quals = "|".join(f"{k}={qualifiers[k]}" for k in sorted(qualifiers))
    return "visionkb:e-" + hashlib.sha1(f"{subject}|{predicate}|{obj}|{quals}".encode()).hexdigest()


def write_csv(path: Path, header: list[str], rows: list[list]) -> None:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(header)
    w.writerows(rows)
    path.write_text(buf.getvalue(), encoding="utf-8")


def build(out: Path, release: str, variant: int) -> Path:
    check_release_id(release)
    genes = GENES + ([GENE_V2] if variant >= 2 else [])
    expr = EXPR + (EXPR_V2 if variant >= 2 else [])
    root = out / release
    if root.exists():
        raise SystemExit(f"{root} exists")
    for sub in ("kgx", "neo4j-import", "summaries", "registry", "validation"):
        (root / sub).mkdir(parents=True)
    (root / "RELEASE").write_text(release + "\n", encoding="utf-8")
    ni = root / "neo4j-import"

    write_csv(
        ni / "nodes_Gene.csv",
        [
            "id:ID",
            ":LABEL",
            "name",
            "category:string[]",
            "symbol",
            "synonym:string[]",
            "xref:string[]",
            "description",
            "in_taxon",
            "provided_by:string[]",
        ],
        [
            [g, "Gene;NamedThing", name, "biolink:Gene", sym, "", x, "", TAXON, "infores:hgnc"]
            for g, sym, name, x in genes
        ],
    )
    write_csv(
        ni / "nodes_Cell.csv",
        ["id:ID", ":LABEL", "name", "category:string[]", "synonym:string[]", "provided_by:string[]"],
        [[c, "Cell;AnatomicalEntity;NamedThing", name, "biolink:Cell", "", "infores:cl"] for c, name in CELLS],
    )
    write_csv(
        ni / "nodes_Dataset.csv",
        [
            "id:ID",
            ":LABEL",
            "name",
            "category:string[]",
            "version",
            "species",
            "tissue:string[]",
            "access_level",
            "description",
            "provided_by:string[]",
        ],
        [
            [
                DATASET,
                "Dataset;NamedThing",
                "Fixture retina dataset",
                "biolink:Dataset",
                ATLAS_VERSION,
                TAXON,
                RETINA,
                "public",
                NOTE,
                "infores:visionkb-heca",
            ]
        ],
    )
    sr_rows, ei_rows, sds_rows, edges, studies = [], [], [], [], []
    for g, c, label, pct, mean, pb in expr:
        quals = {"anatomical_context_qualifier": RETINA, "species_context_qualifier": TAXON}
        eid = edge_id(g, "biolink:expressed_in", c, quals)
        sid = "visionkb:sr-" + eid.split("-", 1)[1][:16]
        n = N_CELLS[label]
        sr_rows.append(
            [
                sid,
                "StudyResult;NamedThing",
                f"{g} in {label} ({DATASET})",
                "biolink:StudyResult",
                eid,
                DATASET,
                ATLAS_VERSION,
                "majorclass",
                label,
                n,
                3,
                pct,
                mean,
                pb,
                3,
                "synthetic-fixture",
            ]
        )
        ei_rows.append(
            [
                g,
                c,
                "expressed_in",
                eid,
                "biolink:expressed_in",
                RETINA,
                TAXON,
                "observation",
                "data_analysis_pipeline",
                "infores:visionkb-heca",
                "",
                "",
                sid,
                1,
                "curated",
                "public",
                release,
                pct,
                mean,
                1,
            ]
        )
        sds_rows.append(
            [
                sid,
                DATASET,
                "supporting_data_set",
                edge_id(sid, "biolink:supporting_data_set", DATASET, {}),
                "biolink:supporting_data_set",
                release,
            ]
        )
        edges.append(
            {
                "id": eid,
                "subject": g,
                "predicate": "biolink:expressed_in",
                "object": c,
                **quals,
                "knowledge_level": "observation",
                "agent_type": "data_analysis_pipeline",
                "primary_knowledge_source": "infores:visionkb-heca",
                "has_study_results": [sid],
            }
        )
        studies.append((g, label, c, n, pct, mean, pb))
    write_csv(
        ni / "nodes_StudyResult.csv",
        [
            "id:ID",
            ":LABEL",
            "name",
            "category:string[]",
            "edge_id",
            "dataset_id",
            "atlas_version",
            "level",
            "group_label",
            "n_cells:int",
            "n_donors:int",
            "pct_expressing:float",
            "mean_log1p_cp10k:float",
            "pseudobulk_cp10k:float",
            "n_donors_expressing:int",
            "method",
        ],
        sr_rows,
    )
    write_csv(
        ni / "rels_expressed_in.csv",
        [
            ":START_ID",
            ":END_ID",
            ":TYPE",
            "id",
            "predicate",
            "anatomical_context_qualifier",
            "species_context_qualifier",
            "knowledge_level",
            "agent_type",
            "primary_knowledge_source",
            "aggregator_knowledge_source:string[]",
            "publications:string[]",
            "has_study_results:string[]",
            "evidence_count:int",
            "status",
            "visibility",
            "kg_release",
            "max_pct_expressing:float",
            "max_mean_log1p_cp10k:float",
            "n_datasets:int",
        ],
        ei_rows,
    )
    sub_rows = []
    for s, o in SUBCLASS:
        eid = edge_id(s, "biolink:subclass_of", o, {})
        sub_rows.append(
            [
                s,
                o,
                "subclass_of",
                eid,
                "biolink:subclass_of",
                "knowledge_assertion",
                "manual_agent",
                "infores:cl",
                "curated",
                "public",
                release,
            ]
        )
        edges.append(
            {
                "id": eid,
                "subject": s,
                "predicate": "biolink:subclass_of",
                "object": o,
                "knowledge_level": "knowledge_assertion",
                "agent_type": "manual_agent",
                "primary_knowledge_source": "infores:cl",
            }
        )
    write_csv(
        ni / "rels_subclass_of.csv",
        [
            ":START_ID",
            ":END_ID",
            ":TYPE",
            "id",
            "predicate",
            "knowledge_level",
            "agent_type",
            "primary_knowledge_source",
            "status",
            "visibility",
            "kg_release",
        ],
        sub_rows,
    )
    write_csv(
        ni / "rels_supporting_data_set.csv",
        [":START_ID", ":END_ID", ":TYPE", "id", "predicate", "kg_release"],
        sds_rows,
    )
    (ni / "import.args").write_text(
        "\n".join(
            [
                "--nodes=nodes_Gene.csv",
                "--nodes=nodes_Cell.csv",
                "--nodes=nodes_Dataset.csv",
                "--nodes=nodes_StudyResult.csv",
                "--relationships=rels_expressed_in.csv",
                "--relationships=rels_subclass_of.csv",
                "--relationships=rels_supporting_data_set.csv",
                "--array-delimiter=;",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (ni / "post_import.cypher").write_text(
        """// Applied once after neo4j-admin import (contracts section 5).
CREATE CONSTRAINT named_thing_id IF NOT EXISTS FOR (n:NamedThing) REQUIRE n.id IS UNIQUE;
CREATE FULLTEXT INDEX entity_search IF NOT EXISTS FOR (n:NamedThing) ON EACH [n.name, n.symbol, n.synonym];
CREATE INDEX study_result_edge_id IF NOT EXISTS FOR (s:StudyResult) ON (s.edge_id);
CREATE INDEX expressed_in_id IF NOT EXISTS FOR ()-[r:expressed_in]-() ON (r.id);
CREATE INDEX subclass_of_id IF NOT EXISTS FOR ()-[r:subclass_of]-() ON (r.id);
""",
        encoding="utf-8",
    )

    nodes = (
        [{"id": g, "category": ["biolink:Gene"], "name": n, "symbol": s, "in_taxon": TAXON} for g, s, n, _ in genes]
        + [{"id": c, "category": ["biolink:Cell"], "name": n} for c, n in CELLS]
        + [{"id": DATASET, "category": ["biolink:Dataset"], "name": "Fixture retina dataset"}]
    )
    (root / "kgx" / "nodes.jsonl").write_text("".join(json.dumps(n) + "\n" for n in nodes), encoding="utf-8")
    (root / "kgx" / "edges.jsonl").write_text("".join(json.dumps(e) + "\n" for e in edges), encoding="utf-8")
    registry = {
        "id": DATASET,
        "version": ATLAS_VERSION,
        "title": "Fixture retina dataset",
        "species": TAXON,
        "tissue": [RETINA],
        "assay": None,
        "stage": None,
        "n_cells": sum(N_CELLS.values()),
        "n_donors": 3,
        "n_samples": 3,
        "levels": ["majorclass"],
        "cell_types": ["CL:0000604", "CL:0000573"],
        "format": "soma",
        "h5ad_path": None,
        "soma_uri": None,
        "checksum": None,
        "access_level": "public",
        "license": "MIT",
        "citation": None,
        "kg_release": release,
        "bind": None,
        "note": NOTE,
    }
    (root / "registry" / "datasets.jsonl").write_text(json.dumps(registry) + "\n", encoding="utf-8")
    summary_sha = None
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq

        sym = {g: s for g, s, _, _ in genes}
        cols = {
            "dataset_id": [DATASET] * len(studies),
            "atlas_version": [ATLAS_VERSION] * len(studies),
            "level": ["majorclass"] * len(studies),
            "group_label": [s[1] for s in studies],
            "cell_type_id": [s[2] for s in studies],
            "region": pa.nulls(len(studies), pa.string()),
            "gene_id": [s[0] for s in studies],
            "gene_symbol": [sym[s[0]] for s in studies],
            "n_cells": [s[3] for s in studies],
            "n_donors": [3] * len(studies),
            "n_expressing": [round(s[3] * s[4]) for s in studies],
            "pct_expressing": [s[4] for s in studies],
            "mean_log1p_cp10k": [s[5] for s in studies],
            "pseudobulk_cp10k": [s[6] for s in studies],
            "n_donors_expressing": [3] * len(studies),
        }
        pq.write_table(pa.table(cols), root / "summaries" / "expr_summary.parquet")
        summary_sha = sha256_file(root / "summaries" / "expr_summary.parquet")
    except ImportError:
        (root / "summaries").rmdir()
        print("note: pyarrow not available; summaries/expr_summary.parquet not written", file=sys.stderr)
    (root / "validation" / "report.json").write_text(
        json.dumps({"status": "pass", "n_errors": 0, "n_warnings": 0, "note": NOTE}, indent=2) + "\n", encoding="utf-8"
    )
    (root / "validation" / "report.md").write_text(
        f"# Validation: {release}\n\nFixture release ({NOTE}). Status: pass.\n", encoding="utf-8"
    )

    files = []
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name != "manifest.json":
            files.append({"path": p.relative_to(root).as_posix(), "bytes": p.stat().st_size, "sha256": sha256_file(p)})
    manifest = {
        "kg_release": release,
        "created_utc": "2026-11-09T00:00:00Z",
        "biolink_version": "4.4.6",
        "schema_version": "fixture",
        "code": {"visionkb-kg": "fixture", "visionkb-atlas": "fixture"},
        "sources": [
            {
                "name": "fixture",
                "version": "0",
                "path_or_url": "synthetic",
                "sha256": None,
                "license": "MIT",
                "infores": "infores:visionkb-heca",
            }
        ],
        "atlases": [{"dataset_id": DATASET, "atlas_version": ATLAS_VERSION, "summary_sha256": summary_sha}],
        "counts": {
            "nodes_by_category": {
                "biolink:Gene": len(genes),
                "biolink:Cell": len(CELLS),
                "biolink:Dataset": 1,
                "biolink:StudyResult": len(expr),
            },
            "edges_by_predicate": {
                "biolink:expressed_in": len(expr),
                "biolink:subclass_of": len(SUBCLASS),
                "biolink:supporting_data_set": len(expr),
            },
            "study_results": len(expr),
        },
        "validation": {"status": "pass", "n_errors": 0, "n_warnings": 0},
        "files": files,
        "fixture": True,
        "note": NOTE,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return root


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out_dir")
    ap.add_argument("kg_release")
    ap.add_argument("--variant", type=int, default=1, choices=(1, 2))
    a = ap.parse_args()
    print(build(Path(a.out_dir), a.kg_release, a.variant))
    return 0


if __name__ == "__main__":
    sys.exit(main())
