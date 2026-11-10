#!/usr/bin/env python3
"""Talk MCP (JSON-RPC over stdio) to a visionkb-kg server command and print one JSON summary line.

    mcp_stdio_check.py [--no-token] -- CMD [ARG...]

CMD starts the server (for example `apptainer exec ... mcp-visionkb-kg.sif visionkb-kg-mcp`). The client
initialises, lists the tools and calls get_release, search_entities(q=RHO) and two pages of
get_relationships(object=CL:0000604, limit=1), the second at offset = paging.next_offset; with --no-token
only search_entities, to see the unauthorized error. Stdlib only.
Exit status 0 when the protocol exchange worked; the caller checks the summary.
"""

from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading

TIMEOUT_S = 180  # first call includes container start-up


class Session:
    def __init__(self, cmd: list[str]) -> None:
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.lines: queue.Queue[str | None] = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.next_id = 0

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, msg: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict | None = None) -> dict:
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        while True:
            line = self.lines.get(timeout=TIMEOUT_S)
            if line is None:
                raise RuntimeError(f"server exited (rc={self.proc.poll()}) before answering {method}")
            try:
                msg = json.loads(line)
            except ValueError:
                continue  # not a JSON-RPC line
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    def call(self, name: str, arguments: dict) -> tuple[dict, int]:
        res = self.request("tools/call", {"name": name, "arguments": arguments})
        text = "".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        data = res.get("structuredContent")
        if data is None:
            data = json.loads(text) if text else {}
        if isinstance(data, dict) and set(data) == {"result"}:
            data = data["result"]
        return data, len(text)

    def close(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main(argv: list[str]) -> int:
    no_token = "--no-token" in argv[: argv.index("--")] if "--" in argv else False
    if "--" not in argv or argv.index("--") == len(argv) - 1:
        print(__doc__, file=sys.stderr)
        return 2
    s = Session(argv[argv.index("--") + 1 :])
    out: dict = {}
    try:
        init = s.request(
            "initialize",
            {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}},
        )
        s.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        out["server"] = init.get("serverInfo", {})
        out["protocol"] = init.get("protocolVersion")
        out["tools"] = sorted(t["name"] for t in s.request("tools/list").get("tools", []))
        sizes = []
        hit, n = s.call("search_entities", {"q": "RHO", "limit": 3})
        sizes.append(n)
        out["search_entities"] = {
            "status": hit.get("status"),
            "kg_release": hit.get("kg_release"),
            "error": (hit.get("error") or {}).get("code"),
            "ids": [d.get("id") for d in hit.get("data") or []],
        }
        if not no_token:
            rel, n = s.call("get_release", {})
            sizes.append(n)
            data = rel.get("data") or {}
            out["get_release"] = {
                "status": rel.get("status"),
                "kg_release": rel.get("kg_release"),
                "ready": data.get("ready"),
            }
            args = {"object": "CL:0000604", "limit": 1}
            p1, n = s.call("get_relationships", args)
            sizes.append(n)
            pg1 = p1.get("paging") or {}
            out["get_relationships"] = {
                "status": p1.get("status"),
                "returned": pg1.get("returned"),
                "total": pg1.get("total"),
                "has_next_offset": "next_offset" in pg1,
                "next_offset": pg1.get("next_offset"),
            }
            if isinstance(pg1.get("next_offset"), int):
                p2, n = s.call("get_relationships", {**args, "offset": pg1["next_offset"]})
                sizes.append(n)
                pg2 = p2.get("paging") or {}
                ids1 = [e.get("edge_id") for e in p1.get("data") or []]
                ids2 = [e.get("edge_id") for e in p2.get("data") or []]
                out["get_relationships_page2"] = {
                    "status": p2.get("status"),
                    "offset": pg2.get("offset"),
                    "returned": pg2.get("returned"),
                    "new_edges": bool(ids2) and not set(ids1) & set(ids2),
                }
        out["max_result_chars"] = max(sizes)
    finally:
        s.close()
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
