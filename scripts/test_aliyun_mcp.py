#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在 Harness 之外直接验证「阿里云文档 MCP + 静态凭证」这条链路：
起 uvx 代理 → 走 MCP 的 stdio 协议 → initialize → tools/list。

这样不用装插件、不用重启 Harness 就能确认 AK / 端点 / 权限是否都对。

前置：环境变量里已有
    ALIBABA_CLOUD_ACCESS_KEY_ID
    ALIBABA_CLOUD_ACCESS_KEY_SECRET
（可选）已经跑过一次应用授权预检查：
    .tools\\uv\\uvx.exe alibabacloud.mcp-proxy@latest --server-url pre-check

用法：
    python scripts/test_aliyun_mcp.py
    python scripts/test_aliyun_mcp.py --endpoint https://.../mcp
"""
import argparse
import json
import os
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UVX = os.path.join(ROOT, ".tools", "uv", "uvx.exe")
DEFAULT_ENDPOINT = ("https://openapi-mcp.cn-hangzhou.aliyuncs.com/"
                    "id/dE5njlweetIpqGcb/mcp")


def send(proc, obj):
    line = json.dumps(obj, ensure_ascii=False)
    proc.stdin.write(line + "\n")
    proc.stdin.flush()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    ap.add_argument("--timeout", type=int, default=60)
    args = ap.parse_args()

    if not os.path.exists(UVX):
        sys.exit(f"找不到 uvx：{UVX}（先下载 uv 到 .tools/uv）")
    if not os.environ.get("ALIBABA_CLOUD_ACCESS_KEY_ID"):
        print("警告：环境变量 ALIBABA_CLOUD_ACCESS_KEY_ID 未设置，代理大概率会认证失败\n")

    env = dict(os.environ)
    env.setdefault("UV_CACHE_DIR", os.path.join(ROOT, ".tools", "uv-cache"))
    env.setdefault("UV_PYTHON_INSTALL_DIR", os.path.join(ROOT, ".tools", "uv-python"))

    cmd = [UVX, "alibabacloud.mcp-proxy@latest", "--server-url", args.endpoint]
    print("启动：", " ".join(cmd))
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", env=env, bufsize=1,
    )

    def drain_stderr():
        for ln in proc.stderr:
            ln = ln.rstrip()
            if ln:
                print("  [proxy]", ln[:200])

    threading.Thread(target=drain_stderr, daemon=True).start()

    try:
        send(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                               "clientInfo": {"name": "dsh-probe", "version": "1.0"}}})
        send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})

        got = 0
        while got < 2:
            line = proc.stdout.readline()
            if not line:
                print("代理已退出，没有更多输出")
                break
            line = line.strip()
            if not line.startswith("{"):
                continue
            msg = json.loads(line)
            rid = msg.get("id")
            if rid == 1:
                info = (msg.get("result") or {}).get("serverInfo") or {}
                print(f"✅ initialize 成功：{info.get('name')} {info.get('version')}")
                got += 1
            elif rid == 2:
                tools = (msg.get("result") or {}).get("tools") or []
                print(f"✅ tools/list 成功：{len(tools)} 个工具")
                for t in tools[:12]:
                    print("   -", t.get("name"))
                got += 1
            elif "error" in msg:
                print("❌ 错误：", json.dumps(msg["error"], ensure_ascii=False)[:400])
                break
    finally:
        try:
            proc.terminate()
        except Exception:
            pass


if __name__ == "__main__":
    main()
