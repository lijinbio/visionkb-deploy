"""Tests for visionkb_deploy.bundle on synthetic fixture releases."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "src"))
sys.path.insert(0, str(REPO / "tests" / "fixtures"))

from make_fixture_release import build  # noqa: E402

from visionkb_deploy import bundle  # noqa: E402

R1 = "visionkb-0000.01.1"


@pytest.fixture
def release(tmp_path: Path) -> Path:
    return build(tmp_path / "releases", R1, 1)


def test_fixture_verifies(release: Path) -> None:
    report = bundle.verify_release_dir(release, expected=R1)
    assert report["ok"] and report["kg_release"] == R1
    assert report["import_files"] == 7


def test_size_and_checksum_tamper_detected(release: Path) -> None:
    target = release / "neo4j-import" / "nodes_Gene.csv"
    data = target.read_bytes()
    target.write_bytes(data[:-2] + b"XX")  # same size, different content
    with pytest.raises(bundle.VerifyError, match="sha256 mismatch"):
        bundle.verify_release_dir(release)
    bundle.verify_release_dir(release, deep=False)  # size-only still passes
    target.write_bytes(data + b"x")
    with pytest.raises(bundle.VerifyError, match="size"):
        bundle.verify_release_dir(release, deep=False)


def test_unlisted_and_symlinked_files_rejected(release: Path, tmp_path: Path) -> None:
    (release / "extra.txt").write_text("x")
    with pytest.raises(bundle.VerifyError, match="not listed"):
        bundle.verify_release_dir(release)
    (release / "extra.txt").unlink()
    outside = tmp_path / "outside.txt"
    outside.write_text("x")
    (release / "link.txt").symlink_to(outside)
    with pytest.raises(bundle.VerifyError, match="symlink"):
        bundle.verify_release_dir(release)


def test_release_mismatch(release: Path) -> None:
    with pytest.raises(bundle.VerifyError, match="expected release"):
        bundle.verify_release_dir(release, expected="visionkb-0000.01.9")
    (release / "RELEASE").write_text("visionkb-0000.01.9\n")
    with pytest.raises(bundle.VerifyError, match="RELEASE says"):
        bundle.verify_release_dir(release)


def test_import_args_must_reference_manifest_files(release: Path) -> None:
    args = release / "neo4j-import" / "import.args"
    args.write_text(args.read_text() + "--nodes=Gene=nodes_Missing.csv\n")
    manifest = json.loads((release / "manifest.json").read_text())
    for f in manifest["files"]:
        if f["path"] == "neo4j-import/import.args":
            f["bytes"] = args.stat().st_size
            f["sha256"] = bundle.sha256_file(args)
    (release / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(bundle.VerifyError, match=r"nodes_Missing\.csv"):
        bundle.verify_release_dir(release)


@pytest.mark.parametrize(
    ("text", "files"),
    [
        ("--nodes=a.csv\n--relationships=T=b.csv,c.csv\n--array-delimiter=;\n", ["a.csv", "b.csv", "c.csv"]),
        ("# c\n\n--nodes=L1:L2=h.csv,d.csv\n", ["h.csv", "d.csv"]),
    ],
)
def test_import_args_files(text: str, files: list[str]) -> None:
    assert bundle.import_args_files(text) == files


def test_import_args_rejects_positional() -> None:
    with pytest.raises(bundle.VerifyError):
        bundle.import_args_files("nodes.csv\n")


def test_pack_unpack_roundtrip_is_deterministic(release: Path, tmp_path: Path) -> None:
    a = bundle.pack_release(release, tmp_path / "b1")
    b = bundle.pack_release(release, tmp_path / "b2")
    assert a["bundle_sha256"] == b["bundle_sha256"]
    with tarfile.open(a["bundle"]) as tar:
        names = tar.getnames()
    assert all(n == R1 or n.startswith(R1 + "/") for n in names)
    rep = bundle.unpack_bundle(a["bundle"], tmp_path / "dest", expected=R1)
    assert rep["action"] == "unpacked"
    assert bundle.unpack_bundle(a["bundle"], tmp_path / "dest")["action"] == "already-unpacked"
    with pytest.raises(bundle.VerifyError, match="exists"):
        bundle.pack_release(release, tmp_path / "b1")


def test_unpack_flat_bundle_without_top_folder(release: Path, tmp_path: Path) -> None:
    tar_path = tmp_path / f"{R1}.tar"
    with tarfile.open(tar_path, "w") as tar:
        for p in sorted(release.rglob("*")):
            if p.is_file():
                tar.add(p, arcname=p.relative_to(release).as_posix())
    (tmp_path / f"{R1}.tar.sha256").write_text(bundle.sha256_file(tar_path) + "\n")
    rep = bundle.unpack_bundle(tar_path, tmp_path / "dest")
    assert rep["kg_release"] == R1


def _evil_bundle(tmp_path: Path, member: tarfile.TarInfo, data: bytes = b"x") -> Path:
    tar_path = tmp_path / f"{R1}.tar"
    with tarfile.open(tar_path, "w") as tar:
        tar.addfile(member, io.BytesIO(data) if member.isfile() else None)
    (tmp_path / f"{R1}.tar.sha256").write_text(f"{bundle.sha256_file(tar_path)}  {R1}.tar\n")
    return tar_path


def test_unpack_rejects_traversal(tmp_path: Path) -> None:
    ti = tarfile.TarInfo(f"{R1}/../../evil.txt")
    ti.size = 1
    with pytest.raises(bundle.VerifyError, match="unsafe path"):
        bundle.unpack_bundle(_evil_bundle(tmp_path, ti), tmp_path / "dest")
    assert not (tmp_path / "evil.txt").exists()


def test_colon_in_names_rejected(release: Path) -> None:
    with pytest.raises(bundle.VerifyError, match="contains ':'"):
        bundle.safe_relpath("atlas/visionkb:ds-x/file.parquet")
    (release / "registry" / "visionkb:ds-x.json").write_text("{}")
    with pytest.raises(bundle.VerifyError, match="not listed"):
        bundle.verify_release_dir(release)


def test_unpack_rejects_links(tmp_path: Path) -> None:
    ti = tarfile.TarInfo(f"{R1}/link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "/etc/passwd"
    with pytest.raises(bundle.VerifyError, match="only regular files"):
        bundle.unpack_bundle(_evil_bundle(tmp_path, ti), tmp_path / "dest")


def test_bad_outer_checksum(release: Path, tmp_path: Path) -> None:
    rep = bundle.pack_release(release, tmp_path / "b")
    Path(rep["bundle"] + ".sha256").write_text("0" * 64 + "\n")
    with pytest.raises(bundle.VerifyError, match="sha256"):
        bundle.unpack_bundle(rep["bundle"], tmp_path / "dest")
    assert not (tmp_path / "dest" / R1).exists()


def test_fetch_from_file_url(release: Path, tmp_path: Path) -> None:
    rep = bundle.pack_release(release, tmp_path / "pub")
    url = Path(rep["bundle"]).as_uri()
    out = bundle.fetch_bundle(url, tmp_path / "dl", tmp_path / "dest", expected=R1)
    assert out["action"] == "unpacked" and out["url"] == url


def test_compare_counts(release: Path, tmp_path: Path) -> None:
    loaded = tmp_path / "LOADED.json"
    loaded.write_text(json.dumps({"kg_release": R1, "nodes": 11, "relationships": 10}))
    assert not bundle.compare_counts(release, loaded)["errors"]
    loaded.write_text(json.dumps({"kg_release": R1, "nodes": 12, "relationships": 10}))
    with pytest.raises(bundle.VerifyError, match="nodes"):
        bundle.compare_counts(release, loaded)


def test_cli_exit_codes(release: Path) -> None:
    script = REPO / "src" / "visionkb_deploy" / "bundle.py"
    ok = subprocess.run([sys.executable, str(script), "verify-dir", str(release)], capture_output=True, text=True)
    assert ok.returncode == 0 and "status: ok" in ok.stdout
    (release / "RELEASE").write_text("bad\n")
    bad = subprocess.run([sys.executable, str(script), "verify-dir", str(release)], capture_output=True, text=True)
    assert bad.returncode == 1 and "FAILED" in bad.stderr
    usage = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert usage.returncode == 2


def test_expected_ids_fixture(release: Path, tmp_path: Path) -> None:
    rep = bundle.expected_ids(release, tmp_path / "exp")
    assert (rep["n_nodes"], rep["n_rels"]) == (11, 10)
    nodes = (tmp_path / "exp" / "nodes.ids").read_text().splitlines()
    assert nodes == sorted(nodes, key=str.encode) and '"HGNC:10012"' in nodes
    rels = (tmp_path / "exp" / "rels.ids").read_text().splitlines()
    assert any(r.startswith('"CL:0000604|subclass_of|CL:0010009|visionkb:e-') for r in rels)
    assert json.loads((tmp_path / "exp" / "ids.json").read_text())["nodes_sha256"] == rep["nodes_sha256"]


def _mini_release(tmp_path: Path, args: str, files: dict[str, str]) -> Path:
    root = tmp_path / "r"
    (root / "neo4j-import").mkdir(parents=True)
    (root / "neo4j-import" / "import.args").write_text(args)
    for name, text in files.items():
        (root / "neo4j-import" / name).write_text(text)
    (root / "manifest.json").write_text(json.dumps({"kg_release": R1}))
    return root


def test_expected_ids_formats(tmp_path: Path) -> None:
    root = _mini_release(
        tmp_path,
        "--delimiter=TAB\n--nodes=./h.csv,./d1.csv,d2.csv\n--relationships=rel_x=r.csv\n",
        {
            "h.csv": "id:ID\t:LABEL\n",
            "d1.csv": 'A"q\tX\n',
            "d2.csv": "B\\\\z\tX\n\n",
            "r.csv": ':START_ID\t:END_ID\tw:int\nA"q\tB\\\\z\t1\n',
        },
    )
    rep = bundle.expected_ids(root, tmp_path / "e")
    assert (rep["n_nodes"], rep["n_rels"]) == (2, 1)
    # cypher-shell --format plain: quoted, inner quotes escaped, backslashes as is
    assert (tmp_path / "e" / "nodes.ids").read_text() == '"A\\"q"\n"B\\\\z"\n'
    assert (tmp_path / "e" / "rels.ids").read_text() == '"A\\"q|rel_x|B\\\\z|"\n'


def test_expected_ids_needs_id_property(tmp_path: Path) -> None:
    root = _mini_release(tmp_path, "--nodes=n.csv\n", {"n.csv": ":ID,name\nA,x\n"})
    with pytest.raises(bundle.VerifyError, match="no property name"):
        bundle.expected_ids(root, tmp_path / "e")


def test_compare_counts_v08_totals(release: Path, tmp_path: Path) -> None:
    loaded = tmp_path / "LOADED.json"
    loaded.write_text(json.dumps({"kg_release": R1, "nodes": 11, "relationships": 10}))
    mpath = release / "manifest.json"
    m = json.loads(mpath.read_text())
    assert (m["counts"]["nodes_total"], m["counts"]["edges_total"]) == (11, 10)
    # a category breakdown that does not sum to nodes_total is an error (contracts v0.8 section 13)
    m["counts"]["nodes_by_category"]["biolink:Cell"] += 1
    mpath.write_text(json.dumps(m))
    with pytest.raises(bundle.VerifyError, match="nodes_by_category sums to 12 but nodes_total is 11"):
        bundle.compare_counts(release, loaded)
    # pre-v0.8 manifest without totals: falls back to the sums, with a warning
    del m["counts"]["nodes_total"], m["counts"]["edges_total"]
    m["counts"]["nodes_by_category"]["biolink:Cell"] -= 1
    mpath.write_text(json.dumps(m))
    rep = bundle.compare_counts(release, loaded)
    assert not rep["errors"] and any("nodes_total" in w for w in rep["warnings"])
