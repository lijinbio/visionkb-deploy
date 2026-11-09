"""Verify, pack, unpack and fetch VisionKB KG release bundles (contracts v0.3, sections 1 and 6).

Standard library only and Python >= 3.9, so the same file runs on an HPC node (system python3), on a
Docker host, and inside a stock ``python:3.x-slim`` image in a Kubernetes Job (mounted from a
ConfigMap). Run it as a script: ``python3 bundle.py verify-dir <release_dir>``.

A release directory holds ``RELEASE`` (one line: the release id), ``manifest.json`` and the files the
manifest lists. A bundle is ``<kg_release>.tar`` (relative paths only, optionally under one top-level
``<kg_release>/`` folder) plus ``<kg_release>.tar.sha256``.

Exit codes: 0 ok, 1 verification failed, 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

__version__ = "0.1.1"

RELEASE_ID_RE = re.compile(r"^visionkb-[0-9]{4}\.[0-9]{2}\.[0-9]+$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHUNK = 1 << 20
# Files a deployable release must contain (relative to the release directory).
REQUIRED_FILES = ("RELEASE", "manifest.json", "neo4j-import/import.args", "neo4j-import/post_import.cypher")
# Files that may exist without a manifest entry (the manifest cannot list its own checksum).
UNLISTED_OK = {"manifest.json", "RELEASE"}
IMPORT_FILE_OPTIONS = ("--nodes", "--relationships")
PATTERN_CHARS = set("*?[]()|\\")


class VerifyError(Exception):
    """Verification failed; the message says what and where."""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def check_release_id(release: str) -> str:
    if not RELEASE_ID_RE.match(release or ""):
        raise VerifyError(f"invalid kg_release {release!r} (expected visionkb-YYYY.MM.N)")
    return release


def safe_relpath(name: str) -> str:
    """Return a normalized relative POSIX path, or raise if it is absolute or leaves its root."""
    if not name or "\\" in name or "\x00" in name:
        raise VerifyError(f"unsafe path {name!r}")
    p = PurePosixPath(name)
    if p.is_absolute() or any(part == ".." for part in p.parts):
        raise VerifyError(f"unsafe path {name!r} (absolute or contains '..')")
    if ":" in name:
        raise VerifyError(f"path {name!r} contains ':' (not allowed in file or folder names, contracts section 1)")
    parts = [part for part in p.parts if part not in ("", ".")]
    if not parts:
        raise VerifyError(f"unsafe path {name!r}")
    return "/".join(parts)


def import_args_files(text: str) -> list[str]:
    """Files referenced by --nodes/--relationships lines of a neo4j-admin import argument file.

    Value forms: ``file``, ``Label=file``, ``Label1:Label2=file1,file2``. Returns paths as written.
    """
    files: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("--"):
            raise VerifyError(f"import.args: not an option line: {line!r}")
        opt, sep, value = line.partition("=")
        if opt not in IMPORT_FILE_OPTIONS:
            continue
        if not sep or not value:
            raise VerifyError(f"import.args: {opt} needs '=<files>' on the same line: {line!r}")
        spec = value.split("=", 1)[1] if "=" in value else value
        files.extend(f for f in spec.split(",") if f)
    return files


def load_manifest(release_dir: Path) -> dict:
    path = release_dir / "manifest.json"
    try:
        with open(path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except FileNotFoundError:
        raise VerifyError(f"{path}: missing") from None
    except json.JSONDecodeError as exc:
        raise VerifyError(f"{path}: not valid JSON ({exc})") from None
    if not isinstance(manifest, dict):
        raise VerifyError(f"{path}: top level must be an object")
    return manifest


def _check_listed(root: Path, files: list, deep: bool, errors: list[str]) -> dict[str, dict]:
    listed: dict[str, dict] = {}
    for entry in files:
        try:
            rel = safe_relpath(str(entry.get("path", "")))
        except (VerifyError, AttributeError) as exc:
            errors.append(f"manifest.json files[]: {exc}")
            continue
        if rel in listed:
            errors.append(f"manifest.json lists {rel} twice")
        listed[rel] = entry
        path = root / rel
        if path.is_symlink():
            errors.append(f"{rel}: is a symlink (bundles must be self-contained)")
            continue
        if not path.is_file():
            errors.append(f"{rel}: listed in manifest but missing")
            continue
        size = path.stat().st_size
        if entry.get("bytes") is not None and int(entry["bytes"]) != size:
            errors.append(f"{rel}: size {size} != manifest bytes {entry['bytes']}")
            continue
        want = str(entry.get("sha256", "")).lower()
        if not SHA256_RE.match(want):
            errors.append(f"{rel}: manifest sha256 missing or malformed")
            continue
        if deep and sha256_file(path) != want:
            errors.append(f"{rel}: sha256 mismatch")
    return listed


def _check_import_args(root: Path, listed: dict[str, dict], errors: list[str], warnings: list[str]) -> int:
    args_path = root / "neo4j-import" / "import.args"
    if not args_path.is_file():
        return 0
    try:
        import_files = import_args_files(args_path.read_text(encoding="utf-8"))
    except VerifyError as exc:
        errors.append(str(exc))
        return 0
    if not import_files:
        errors.append("import.args lists no --nodes/--relationships files")
    for f in import_files:
        try:
            rel = "neo4j-import/" + safe_relpath(f)
        except VerifyError as exc:
            errors.append(f"import.args: {exc}")
            continue
        if PATTERN_CHARS & set(f):
            warnings.append(f"import.args: {f} looks like a pattern; not checked")
        elif rel not in listed:
            errors.append(f"import.args references {f}, which is not in the manifest")
    return len(import_files)


def verify_release_dir(release_dir: str | os.PathLike, expected: str | None = None, deep: bool = True) -> dict:
    """Check a release directory against its manifest. Returns a report; raises VerifyError on failure.

    deep=False skips the sha256 of each file (sizes are still checked).
    """
    root = Path(release_dir)
    if not root.is_dir():
        raise VerifyError(f"{root}: not a directory")
    errors: list[str] = []
    warnings: list[str] = []

    for rel in REQUIRED_FILES:
        if not (root / rel).is_file():
            errors.append(f"required file missing: {rel}")
    release_line = ""
    if (root / "RELEASE").is_file():
        release_line = (root / "RELEASE").read_text(encoding="utf-8").strip()
    manifest = load_manifest(root)
    release = manifest.get("kg_release")
    if not isinstance(release, str):
        raise VerifyError("manifest.json: kg_release missing")
    check_release_id(release)
    if release_line and release_line != release:
        errors.append(f"RELEASE says {release_line!r} but manifest kg_release is {release!r}")
    if expected and expected != release:
        errors.append(f"expected release {expected!r} but manifest kg_release is {release!r}")
    if root.name != release and not root.name.endswith(".partial"):
        warnings.append(f"directory name {root.name!r} differs from kg_release {release!r}")
    for key in ("created_utc", "biolink_version", "files", "counts"):
        if key not in manifest:
            errors.append(f"manifest.json: field {key!r} missing")
    files = manifest.get("files") or []
    if not isinstance(files, list):
        raise VerifyError("manifest.json: files must be a list")

    listed = _check_listed(root, files, deep, errors)

    present: set[str] = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames + [d for d in dirnames if (Path(dirpath) / d).is_symlink()]:
            rel = (Path(dirpath) / name).relative_to(root).as_posix()
            present.add(rel)
            if (Path(dirpath) / name).is_symlink() and rel not in listed:
                errors.append(f"{rel}: symlink in release (bundles must be self-contained)")
    for rel in sorted(present - set(listed) - UNLISTED_OK):
        errors.append(f"{rel}: present but not listed in manifest.json")

    n_import = _check_import_args(root, listed, errors, warnings)
    report = {
        "kg_release": release,
        "release_dir": str(root),
        "n_files": len(listed),
        "bytes": sum(int(e.get("bytes") or 0) for e in listed.values()),
        "import_files": n_import,
        "checksums": "sha256" if deep else "size-only",
        "errors": errors,
        "warnings": warnings,
        "ok": not errors,
    }
    if errors:
        shown = "; ".join(errors[:10]) + (f"; ... {len(errors) - 10} more" if len(errors) > 10 else "")
        raise VerifyError(f"release {release} at {root} failed verification: {shown}")
    return report


def read_sha256_file(path: Path) -> str:
    """Return the hex digest from a ``sha256sum``-style file (``<hex>  <name>``) or a bare digest."""
    text = path.read_text(encoding="utf-8").strip()
    token = text.split()[0].lower() if text else ""
    if not SHA256_RE.match(token):
        raise VerifyError(f"{path}: no sha256 digest found")
    return token


def verify_bundle_checksum(bundle: Path, sha_file: Path | None = None) -> str:
    sha_file = sha_file or Path(str(bundle) + ".sha256")
    if not bundle.is_file():
        raise VerifyError(f"{bundle}: bundle missing")
    if not sha_file.is_file():
        raise VerifyError(f"{sha_file}: checksum file missing")
    want = read_sha256_file(sha_file)
    got = sha256_file(bundle)
    if got != want:
        raise VerifyError(f"{bundle}: sha256 {got} != {sha_file.name} {want}")
    return got


def _bundle_members(tar: tarfile.TarFile, expected: str | None) -> tuple[str, list[tuple[tarfile.TarInfo, str]]]:
    """Validate members; return (release id, [(member, relative path inside the release)])."""
    names: list[tuple[tarfile.TarInfo, str]] = []
    for m in tar.getmembers():
        if not (m.isfile() or m.isdir()):
            raise VerifyError(f"bundle member {m.name!r}: only regular files and directories are allowed")
        names.append((m, safe_relpath(m.name)))
    files = [rel for m, rel in names if m.isfile()]
    if not files:
        raise VerifyError("bundle is empty")
    tops = {rel.split("/", 1)[0] for _, rel in names}
    prefix = ""
    if len(tops) == 1 and "RELEASE" not in files:
        prefix = tops.pop() + "/"
    out: list[tuple[tarfile.TarInfo, str]] = []
    for m, rel in names:
        if prefix and rel + "/" == prefix:
            continue
        out.append((m, rel[len(prefix) :] if prefix else rel))
    release = expected
    if prefix:
        release = prefix.rstrip("/")
        if expected and release != expected:
            raise VerifyError(f"bundle top-level folder {release!r} != expected release {expected!r}")
    if not release:
        rel_member = next((m for m, inner in out if inner == "RELEASE" and m.isfile()), None)
        if rel_member is None:
            raise VerifyError("bundle has no RELEASE file")
        fh = tar.extractfile(rel_member)
        release = fh.read().decode("utf-8").strip() if fh else ""
    return check_release_id(release), out


def unpack_bundle(bundle: str | os.PathLike, dest_parent: str | os.PathLike, expected: str | None = None) -> dict:
    """Verify the outer sha256, extract into ``<dest_parent>/<kg_release>/`` and verify the manifest.

    Extraction goes to a ``.partial`` folder first and is renamed only after verification.
    If the release is already unpacked and verifies, it is kept (idempotent).
    """
    bundle = Path(bundle)
    digest = verify_bundle_checksum(bundle)
    dest_parent = Path(dest_parent)
    dest_parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(bundle, "r:*") as tar:
        release, members = _bundle_members(tar, expected)
        final = dest_parent / release
        if final.exists():
            report = verify_release_dir(final, expected=release)
            report.update(bundle=str(bundle), bundle_sha256=digest, action="already-unpacked")
            return report
        partial = dest_parent / (release + ".partial")
        if partial.exists():
            shutil.rmtree(partial)
        partial.mkdir()
        try:
            for m, inner in members:
                target = partial / inner
                if m.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                src = tar.extractfile(m)
                if src is None:
                    raise VerifyError(f"bundle member {m.name!r} unreadable")
                with src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out, CHUNK)
                os.chmod(target, 0o444)
            report = verify_release_dir(partial, expected=release)
        except BaseException:
            shutil.rmtree(partial, ignore_errors=True)
            raise
    os.replace(partial, final)
    report.update(release_dir=str(final), bundle=str(bundle), bundle_sha256=digest, action="unpacked")
    return report


def _tarinfo_filter(ti: tarfile.TarInfo) -> tarfile.TarInfo:
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = 0
    ti.mode = 0o755 if ti.isdir() else 0o644
    return ti


def pack_release(release_dir: str | os.PathLike, out_dir: str | os.PathLike) -> dict:
    """Write a deterministic ``<kg_release>.tar`` (+ ``.sha256``) with a top-level ``<kg_release>/`` folder.

    Used only when ``visionkb-kg pack`` is not available; the release is verified first.
    """
    root = Path(release_dir)
    report = verify_release_dir(root)
    release = report["kg_release"]
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    bundle = out_dir / f"{release}.tar"
    if bundle.exists():
        raise VerifyError(f"{bundle} exists; bundles are immutable (remove it first to rebuild)")
    entries = sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())
    dirs = sorted({str(PurePosixPath(e).parent) for e in entries} - {"."})
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=f".{release}.", suffix=".tar")
    os.close(fd)
    try:
        with tarfile.open(tmp, "w", format=tarfile.PAX_FORMAT) as tar:
            tar.add(root, arcname=release, recursive=False, filter=_tarinfo_filter)
            for d in dirs:
                tar.add(root / d, arcname=f"{release}/{d}", recursive=False, filter=_tarinfo_filter)
            for e in entries:
                tar.add(root / e, arcname=f"{release}/{e}", recursive=False, filter=_tarinfo_filter)
        os.chmod(tmp, 0o644)
        os.replace(tmp, bundle)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    digest = sha256_file(bundle)
    (out_dir / f"{release}.tar.sha256").write_text(f"{digest}  {release}.tar\n", encoding="utf-8")
    return {
        "kg_release": release,
        "bundle": str(bundle),
        "bundle_sha256": digest,
        "bytes": bundle.stat().st_size,
        "n_files": report["n_files"],
        "action": "packed",
    }


def _download(url: str, dest: Path, header: str | None) -> None:
    scheme = urllib.parse.urlparse(url).scheme
    if scheme not in ("https", "http", "file"):
        raise VerifyError(f"unsupported URL scheme {scheme!r} (use https)")
    req = urllib.request.Request(url)
    if header:
        name, sep, value = header.partition(":")
        if not sep or not name.strip():
            raise VerifyError("auth header file must hold one line 'Name: value'")
        req.add_header(name.strip(), value.strip())
    tmp = dest.with_name(dest.name + ".download")
    with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out, CHUNK)
    os.replace(tmp, dest)


def fetch_bundle(url: str, download_dir: str | os.PathLike, dest_parent: str | os.PathLike, **kw) -> dict:
    """Download ``url`` and ``url + '.sha256'``, verify, and unpack into ``dest_parent``.

    Keyword options: ``header_file`` (file with one ``Name: value`` line, e.g. an Authorization header),
    ``sha256_url`` (checksum URL override), ``expected`` (release id that must match).
    """
    header_file = kw.get("header_file")
    header = Path(header_file).read_text(encoding="utf-8").strip() if header_file else None
    download_dir = Path(download_dir)
    download_dir.mkdir(parents=True, exist_ok=True)
    name = PurePosixPath(urllib.parse.urlparse(url).path).name
    if not name.endswith(".tar"):
        raise VerifyError(f"bundle URL must end in .tar: {url}")
    bundle = download_dir / name
    _download(kw.get("sha256_url") or url + ".sha256", Path(str(bundle) + ".sha256"), header)
    have = None
    if bundle.is_file():
        try:
            have = verify_bundle_checksum(bundle)
        except VerifyError:
            have = None
    if have is None:
        _download(url, bundle, header)
    report = unpack_bundle(bundle, dest_parent, expected=kw.get("expected"))
    report["url"] = url
    return report


def compare_counts(release_dir: str | os.PathLike, loaded_json: str | os.PathLike) -> dict:
    """Compare node/relationship totals of a loaded store (LOADED.json) with manifest counts."""
    counts = load_manifest(Path(release_dir)).get("counts") or {}
    loaded = json.loads(Path(loaded_json).read_text(encoding="utf-8"))
    want_nodes = sum(int(v) for v in (counts.get("nodes_by_category") or {}).values())
    want_rels = sum(int(v) for v in (counts.get("edges_by_predicate") or {}).values())
    report = {
        "kg_release": loaded.get("kg_release"),
        "nodes": {"manifest": want_nodes, "loaded": loaded.get("nodes")},
        "relationships": {"manifest": want_rels, "loaded": loaded.get("relationships")},
    }
    errors = []
    if loaded.get("nodes") != want_nodes:
        errors.append(f"nodes: manifest {want_nodes} != loaded {loaded.get('nodes')}")
    if loaded.get("relationships") != want_rels:
        errors.append(f"relationships: manifest {want_rels} != loaded {loaded.get('relationships')}")
    report["errors"] = errors
    if errors:
        raise VerifyError("; ".join(errors))
    return report


def _emit(report: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return
    keys = (
        "kg_release",
        "action",
        "release_dir",
        "bundle",
        "bundle_sha256",
        "n_files",
        "bytes",
        "checksums",
        "nodes",
        "relationships",
    )
    for k in keys:
        if k in report:
            print(f"{k}: {report[k]}")
    for w in report.get("warnings", []):
        print(f"warning: {w}")
    print("status: ok")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="visionkb-bundle", description="Verify, pack, unpack and fetch KG bundles.")
    ap.add_argument("--version", action="version", version=__version__)
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("verify-dir", help="verify a release directory against manifest.json")
    p.add_argument("release_dir")
    p.add_argument("--release", help="release id that must match")
    p.add_argument("--size-only", action="store_true", help="check sizes, skip sha256 of each file")
    p = sub.add_parser("verify-bundle", help="verify <bundle>.tar against <bundle>.tar.sha256")
    p.add_argument("bundle")
    p = sub.add_parser("unpack", help="verify and unpack a bundle into DEST/<kg_release>/")
    p.add_argument("bundle")
    p.add_argument("--dest", required=True)
    p.add_argument("--release", help="release id that must match")
    p = sub.add_parser("pack", help="write <kg_release>.tar + .sha256 from a verified release directory")
    p.add_argument("release_dir")
    p.add_argument("--out", required=True)
    p = sub.add_parser("fetch", help="download a bundle (+ .sha256) over HTTPS, verify and unpack")
    p.add_argument("url")
    p.add_argument("--download-dir", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--release", help="release id that must match")
    p.add_argument("--header-file", help="file with one 'Name: value' request header")
    p.add_argument("--sha256-url")
    p = sub.add_parser("compare-counts", help="compare LOADED.json totals with manifest counts")
    p.add_argument("release_dir")
    p.add_argument("loaded_json")
    p = sub.add_parser("import-files", help="list files referenced by a neo4j-admin import.args")
    p.add_argument("import_args")
    return ap


def main(argv: list[str] | None = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        if a.cmd == "verify-dir":
            _emit(verify_release_dir(a.release_dir, expected=a.release, deep=not a.size_only), a.json)
        elif a.cmd == "verify-bundle":
            _emit({"bundle": a.bundle, "bundle_sha256": verify_bundle_checksum(Path(a.bundle))}, a.json)
        elif a.cmd == "unpack":
            _emit(unpack_bundle(a.bundle, a.dest, expected=a.release), a.json)
        elif a.cmd == "pack":
            _emit(pack_release(a.release_dir, a.out), a.json)
        elif a.cmd == "fetch":
            kw = {"expected": a.release, "header_file": a.header_file, "sha256_url": a.sha256_url}
            _emit(fetch_bundle(a.url, a.download_dir, a.dest, **kw), a.json)
        elif a.cmd == "compare-counts":
            _emit(compare_counts(a.release_dir, a.loaded_json), a.json)
        elif a.cmd == "import-files":
            for f in import_args_files(Path(a.import_args).read_text(encoding="utf-8")):
                print(f)
    except (VerifyError, OSError, ValueError) as exc:
        print(f"visionkb-bundle: FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
