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

__version__ = "0.1.8"

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


def import_args_specs(text: str) -> tuple[list[tuple[str, str, list[str]]], dict[str, str]]:
    """Parse import.args into ([(option, label_or_type_prefix, files)], other options)."""
    specs: list[tuple[str, str, list[str]]] = []
    options: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("--"):
            raise VerifyError(f"import.args: not an option line: {line!r}")
        opt, _, value = line.partition("=")
        if opt in IMPORT_FILE_OPTIONS:
            prefix, files = value.split("=", 1) if "=" in value else ("", value)
            specs.append((opt, prefix, [f for f in files.split(",") if f]))
        else:
            options[opt] = value
    return specs, options


def _csv_char(value: str | None, default: str) -> str:
    if value is None or value == "":
        return default
    v = value.strip("'\"") if len(value) > 1 else value
    return {"TAB": "\t", "\\t": "\t"}.get(v, v)


def _plain(value: str) -> str:
    """A string value as cypher-shell --format plain prints it (quotes escaped, nothing else)."""
    if "\n" in value or "\r" in value:
        raise VerifyError(f"id contains a line break: {value!r}")
    return '"' + value.replace('"', '\\"') + '"'


def _csv_rows(paths: list[Path], delimiter: str, quote: str):
    """Header from the first file, data rows from all files (neo4j-admin multi-file semantics)."""
    import csv

    header = None
    for i, path in enumerate(paths):
        with open(path, encoding="utf-8", newline="") as fh:
            reader = csv.reader(fh, delimiter=delimiter, quotechar=quote)
            for j, row in enumerate(reader):
                if i == 0 and j == 0:
                    header = row
                    continue
                if row:
                    yield header, row


def expected_ids(release_dir: str | os.PathLike, out_dir: str | os.PathLike) -> dict:
    """Write the node ids and relationship keys a correct import must contain (contracts section 5).

    nodes.ids: one line per node, the value of the ``<prop>:ID`` column. rels.ids: one line per relationship,
    ``start|type|end|id`` (``id`` = the ``id`` property column, empty if absent). Each line is formatted as
    ``cypher-shell --format plain`` prints a string, so the loader can compare its dump byte for byte.
    Both files are sorted by bytes (= ``LC_ALL=C sort``); ids.json holds counts and sha256 digests.
    """
    root = Path(release_dir)
    imp = root / "neo4j-import"
    specs, options = import_args_specs((imp / "import.args").read_text(encoding="utf-8"))
    delim = _csv_char(options.get("--delimiter"), ",")
    quote = _csv_char(options.get("--quote"), '"')
    nodes: list[str] = []
    rels: list[str] = []
    for opt, prefix, files in specs:
        paths = [imp / safe_relpath(f) for f in files]
        if any(PATTERN_CHARS & set(f) for f in files):
            raise VerifyError(f"import.args: file patterns are not supported by the id check: {files}")
        cols: dict[str, int] | None = None
        for header, row in _csv_rows(paths, delim, quote):
            if cols is None:
                names = [h.split(":", 1) for h in header]
                cols = {}
                for k, parts in enumerate(names):
                    name, typ = parts[0], (parts[1] if len(parts) > 1 else "")
                    if typ.startswith("ID"):
                        cols["ID"] = k
                        cols["ID_prop"] = 1 if name else 0
                    elif typ.startswith("START_ID"):
                        cols["START"] = k
                    elif typ.startswith("END_ID"):
                        cols["END"] = k
                    elif typ == "TYPE":
                        cols["TYPE"] = k
                    elif name == "id":
                        cols["id"] = k
                if opt == "--nodes" and "ID" not in cols:
                    raise VerifyError(f"{files[0]}: no ID column in header")
                if opt == "--nodes" and not cols.get("ID_prop"):
                    raise VerifyError(f"{files[0]}: ID column has no property name (contracts: id:ID)")
                if opt == "--relationships" and not {"START", "END"} <= cols.keys():
                    raise VerifyError(f"{files[0]}: no :START_ID/:END_ID columns")
            if opt == "--nodes":
                nodes.append(_plain(row[cols["ID"]]))
            else:
                rtype = row[cols["TYPE"]] if "TYPE" in cols and row[cols["TYPE"]] else prefix
                rid = row[cols["id"]] if "id" in cols else ""
                rels.append(_plain(f"{row[cols['START']]}|{rtype}|{row[cols['END']]}|{rid}"))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = {"format": "cypher-shell-plain/v1", "kg_release": load_manifest(root).get("kg_release")}
    for name, keys in (("nodes", nodes), ("rels", rels)):
        keys.sort(key=lambda k: k.encode("utf-8"))
        data = "".join(k + "\n" for k in keys).encode("utf-8")
        (out / f"{name}.ids").write_bytes(data)
        report[f"n_{name}"] = len(keys)
        report[f"{name}_sha256"] = hashlib.sha256(data).hexdigest()
    (out / "ids.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


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


Pin = tuple[str, str]


def parse_pin(text: str | None) -> Pin | None:
    """``RELEASE=SHA256`` -> ``(release, sha256)``. An empty text or an empty digest means no pin."""
    if not text:
        return None
    release, sep, digest = text.partition("=")
    digest = digest.strip().lower()
    if not sep:
        raise VerifyError(f"pin must be RELEASE=SHA256 (got {text!r})")
    if not digest:
        return None
    if not SHA256_RE.match(digest):
        raise VerifyError(f"pin for {release!r}: {digest!r} is not a sha256 hex digest")
    return check_release_id(release.strip()), digest


def check_pin(release: str, digest: str, pin: Pin | None, what: str = "bundle") -> None:
    """A bundle of the pinned release must have the pinned outer sha256; other releases are not affected."""
    if pin and release == pin[0] and digest.lower() != pin[1]:
        raise VerifyError(
            f"{release}: {what} sha256 {digest.lower()} != pinned VISIONKB_KG_BUNDLE_SHA256 {pin[1]}"
            " (versions.env / release.env); refusing it"
        )


def bundle_release(bundle: str | os.PathLike, expected: str | None = None) -> str:
    """Release id of a bundle (top-level folder or RELEASE file), after validating its members."""
    with tarfile.open(bundle, "r:*") as tar:
        return _bundle_members(tar, expected)[0]


def verify_bundle(bundle: str | os.PathLike, pin: Pin | None = None, expected: str | None = None) -> dict:
    """Outer sha256 against ``<bundle>.sha256``; with a pin (or ``expected``) also the release id inside."""
    bundle = Path(bundle)
    digest = verify_bundle_checksum(bundle)
    report = {"bundle": str(bundle), "bundle_sha256": digest}
    if pin or expected:
        release = bundle_release(bundle, expected)
        check_pin(release, digest, pin)
        report.update(kg_release=release, pinned=bool(pin and pin[0] == release))
    return report


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


def unpack_bundle(
    bundle: str | os.PathLike, dest_parent: str | os.PathLike, expected: str | None = None, pin: Pin | None = None
) -> dict:
    """Verify the outer sha256 (and the pin, if the bundle is the pinned release), extract into
    ``<dest_parent>/<kg_release>/`` and verify the manifest.

    Extraction goes to a ``.partial`` folder first and is renamed only after verification.
    If the release is already unpacked and verifies, it is kept (idempotent).
    """
    bundle = Path(bundle)
    digest = verify_bundle_checksum(bundle)
    dest_parent = Path(dest_parent)
    dest_parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(bundle, "r:*") as tar:
        release, members = _bundle_members(tar, expected)
        check_pin(release, digest, pin)
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
    ``sha256_url`` (checksum URL override), ``expected`` (release id that must match), ``pin``
    (``(release, sha256)``: the published .sha256 is compared first, so a wrong bundle is not downloaded).
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
    pin = kw.get("pin")
    named = kw.get("expected") or name[: -len(".tar")]
    if pin and named == pin[0]:
        check_pin(named, read_sha256_file(Path(str(bundle) + ".sha256")), pin, what="published .sha256 of the bundle")
    have = None
    if bundle.is_file():
        try:
            have = verify_bundle_checksum(bundle)
        except VerifyError:
            have = None
    if have is None:
        _download(url, bundle, header)
    report = unpack_bundle(bundle, dest_parent, expected=kw.get("expected"), pin=pin)
    report["url"] = url
    return report


def compare_counts(release_dir: str | os.PathLike, loaded_json: str | os.PathLike) -> dict:
    """Compare the loaded store's totals (LOADED.json) with manifest counts (contracts v0.8 section 13).

    ``counts.nodes_total`` / ``counts.edges_total`` are the expected totals; ``nodes_by_category`` and
    ``edges_by_predicate`` must sum to them. Manifests without the totals (before v0.8) fall back to the sums.
    """
    counts = load_manifest(Path(release_dir)).get("counts") or {}
    loaded = json.loads(Path(loaded_json).read_text(encoding="utf-8"))
    errors: list[str] = []
    warnings: list[str] = []
    report: dict = {"kg_release": loaded.get("kg_release")}
    for kind, total_key, by_key, loaded_key in (
        ("nodes", "nodes_total", "nodes_by_category", "nodes"),
        ("relationships", "edges_total", "edges_by_predicate", "relationships"),
    ):
        by = counts.get(by_key) or {}
        by_sum = sum(int(v) for v in by.values())
        total = counts.get(total_key)
        if total is None:
            warnings.append(f"manifest has no counts.{total_key} (contracts v0.8); using the sum of {by_key}")
            want = by_sum
        else:
            want = int(total)
            if by and by_sum != want:
                errors.append(f"manifest: {by_key} sums to {by_sum} but {total_key} is {want}")
        got = loaded.get(loaded_key)
        report[kind] = {"manifest": want, "loaded": got}
        if got != want:
            errors.append(f"{kind}: manifest {want} != loaded {got}")
    report["errors"] = errors
    report["warnings"] = warnings
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
        "n_nodes",
        "n_rels",
        "nodes_sha256",
        "rels_sha256",
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
    p.add_argument("--release", help="release id that must match")
    p.add_argument(
        "--pin", metavar="RELEASE=SHA256", help="a bundle of RELEASE must have this outer sha256 (empty SHA256: no pin)"
    )
    p = sub.add_parser("unpack", help="verify and unpack a bundle into DEST/<kg_release>/")
    p.add_argument("bundle")
    p.add_argument("--dest", required=True)
    p.add_argument("--release", help="release id that must match")
    p.add_argument(
        "--pin", metavar="RELEASE=SHA256", help="a bundle of RELEASE must have this outer sha256 (empty SHA256: no pin)"
    )
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
    p.add_argument(
        "--pin", metavar="RELEASE=SHA256", help="a bundle of RELEASE must have this outer sha256 (empty SHA256: no pin)"
    )
    p = sub.add_parser("compare-counts", help="compare LOADED.json totals with manifest counts")
    p.add_argument("release_dir")
    p.add_argument("loaded_json")
    p = sub.add_parser("expected-ids", help="write sorted node ids / relationship keys from the import CSVs")
    p.add_argument("release_dir")
    p.add_argument("--out", required=True)
    p = sub.add_parser("import-files", help="list files referenced by a neo4j-admin import.args")
    p.add_argument("import_args")
    return ap


def main(argv: list[str] | None = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        if a.cmd == "verify-dir":
            _emit(verify_release_dir(a.release_dir, expected=a.release, deep=not a.size_only), a.json)
        elif a.cmd == "verify-bundle":
            _emit(verify_bundle(a.bundle, pin=parse_pin(a.pin), expected=a.release), a.json)
        elif a.cmd == "unpack":
            _emit(unpack_bundle(a.bundle, a.dest, expected=a.release, pin=parse_pin(a.pin)), a.json)
        elif a.cmd == "pack":
            _emit(pack_release(a.release_dir, a.out), a.json)
        elif a.cmd == "fetch":
            kw = {"expected": a.release, "header_file": a.header_file, "sha256_url": a.sha256_url}
            kw["pin"] = parse_pin(a.pin)
            _emit(fetch_bundle(a.url, a.download_dir, a.dest, **kw), a.json)
        elif a.cmd == "compare-counts":
            _emit(compare_counts(a.release_dir, a.loaded_json), a.json)
        elif a.cmd == "expected-ids":
            _emit(expected_ids(a.release_dir, a.out), a.json)
        elif a.cmd == "import-files":
            for f in import_args_files(Path(a.import_args).read_text(encoding="utf-8")):
                print(f)
    except (VerifyError, OSError, ValueError) as exc:
        print(f"visionkb-bundle: FAILED: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
