#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
鸿蒙官方文档检索（开发者知识 MCP）：https://connect-api.cloud.huawei.com/api/developerknowledge/mcp

文档中心是前端渲染的网页，直接抓 HTML 拿不到正文；这个 MCP 服务返回 Markdown，
专为 AI 读取设计（官方称「与官网准实时同步，延迟 ≤30 分钟」）。

用法：
    python scripts/hsdocs.py search "graphics text paragraph 坐标"        # 检索，列出 parent 标识
    python scripts/hsdocs.py get <parent> [<parent> ...]                  # 取完整文档，存到 docs/vendor/
    python scripts/hsdocs.py get --print <parent>                          # 只打印，不落盘
"""
import argparse
import json
import os
import re
import sys
import urllib.request

MCP_URL = "https://connect-api.cloud.huawei.com/api/developerknowledge/mcp"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "docs", "vendor")


def rpc(method: str, params: dict):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode("utf-8", "replace")
    # 有的实现返回 SSE（data: {...}）
    if raw.lstrip().startswith("data:"):
        for line in raw.splitlines():
            if line.startswith("data:"):
                return json.loads(line[5:].strip())
    return json.loads(raw)


def call_tool(name: str, arguments: dict) -> dict:
    res = rpc("tools/call", {"name": name, "arguments": arguments})
    if "error" in res:
        raise RuntimeError(json.dumps(res["error"], ensure_ascii=False))
    content = res.get("result", {}).get("content", [])
    for block in content:
        if block.get("type") == "text":
            text = block.get("text", "")
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return {"raw": text}
    return {}


def slugify(title: str, fallback: str) -> str:
    s = re.sub(r"[^\w\u4e00-\u9fa5-]+", "-", title).strip("-")
    return (s or fallback)[:80]


def cmd_search(args):
    data = call_tool("searchDocuments", {"SearchDocumentsReq": {"query": args.query, "topK": args.top}})
    items = data.get("resultList", [])
    if not items:
        print("没有结果：", json.dumps(data, ensure_ascii=False)[:400])
        return
    print(f"命中 {len(items)} 条：\n")
    for i, it in enumerate(items, 1):
        parent = it.get("parent", "")
        snippet = re.sub(r"\s+", " ", it.get("content", ""))[:200]
        print(f"{i:>2}. parent = {parent}")
        print(f"    {snippet}\n")
    print("用 `get <parent>` 取全文。")


def cmd_get(args):
    names = args.names
    if not names:
        print("缺 parent 标识")
        sys.exit(1)
    data = call_tool("getDocumentsById", {"GetDocumentsByIdRequest": {"names": names[:10]}})
    docs = data.get("resultList", [])
    if not docs:
        print("没取到文档：", json.dumps(data, ensure_ascii=False)[:600])
        sys.exit(1)
    os.makedirs(OUT_DIR, exist_ok=True)
    for d in docs:
        title = d.get("title") or d.get("name") or "doc"
        content = d.get("content", "")
        uri = d.get("uri", "")
        if args.print:
            print(f"\n===== {title} =====\n{uri}\n")
            print(content)
            continue
        path = os.path.join(OUT_DIR, slugify(title, "doc") + ".md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {title}\n\n> {uri}\n\n{content}")
        print(f"已保存 {path}  ({len(content)} 字符)  {title}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("search", help="检索文档")
    p1.add_argument("query")
    p1.add_argument("--top", type=int, default=10)
    p1.set_defaults(func=cmd_search)

    p2 = sub.add_parser("get", help="取文档全文")
    p2.add_argument("names", nargs="*")
    p2.add_argument("--print", action="store_true", dest="print")
    p2.set_defaults(func=cmd_get)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
