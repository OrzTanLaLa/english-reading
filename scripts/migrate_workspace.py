#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 DSH 会话从旧工作区迁到新工作区。

需要改三处，漏一处会话就断：
  1. ~/.dsh/storages/workspace.json       工作区索引（path + sessionIds）
  2. ~/.dsh/sessions/<编码路径>/           会话日志所在目录
  3. 会话日志首行的 cwd                    运行时据此确认工作区

用法（先关掉 DSH，再跑）：
    python scripts/migrate_workspace.py --apply
    python scripts/migrate_workspace.py --apply --old "..." --new "..."

默认 dry-run，只打印将要做什么。
"""

import argparse
import json
import os
import shutil
import sys

if sys.platform == "win32":
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8")
        except Exception:
            pass

try:
    import compression.zstd as zstd
except ImportError:
    sys.exit("需要 Python 3.14+（compression.zstd）。用 E:\\Program Files\\Python314\\python.exe 跑。")

DSH = os.path.join(os.path.expanduser("~"), ".dsh")
STORES = os.path.join(DSH, "storages", "workspace.json")
SESSIONS = os.path.join(DSH, "sessions")

OLD = r"E:\Project\English Reading"
NEW = r"E:\Project\english-reading"


def encode(path):
    """E:\\Project\\English Reading -> --E-Project-English~0020Reading--"""
    out = []
    for ch in path:
        if ch == ":":
            continue
        if ch in "\\/":
            out.append("-")
        elif ch.isalnum() or ch in "-_.":
            out.append(ch)
        else:
            out.append(f"~{ord(ch):04x}")
    return "--" + "".join(out) + "--"


def patch_cwd(session_file, new_path, apply):
    """改写会话日志首行的 cwd；其余行是历史记录，保持原样。"""
    with open(session_file, "rb") as f:
        raw = f.read()
    text = zstd.decompress(raw).decode("utf-8")
    lines = text.splitlines(keepends=True)
    if not lines:
        return False

    first = json.loads(lines[0])
    if first.get("cwd") == new_path:
        return False
    old_cwd = first.get("cwd")
    first["cwd"] = new_path
    lines[0] = json.dumps(first, ensure_ascii=False, separators=(",", ":")) + "\n"

    if apply:
        shutil.copy2(session_file, session_file + ".bak")
        with open(session_file, "wb") as f:
            f.write(zstd.compress("".join(lines).encode("utf-8")))
    print(f"    cwd: {old_cwd}  ->  {new_path}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", default=OLD)
    ap.add_argument("--new", default=NEW)
    ap.add_argument("--apply", action="store_true", help="真的执行（默认只预览）")
    args = ap.parse_args()
    old, new = os.path.abspath(args.old), os.path.abspath(args.new)

    old_dir, new_dir = encode(old), encode(new)
    print(f"旧工作区  {old}\n           会话目录 {old_dir}")
    print(f"新工作区  {new}\n           会话目录 {new_dir}")
    print(f"执行模式  {'APPLY' if args.apply else 'DRY-RUN'}\n")

    if not os.path.exists(STORES):
        sys.exit(f"找不到 {STORES}")

    with open(STORES, "r", encoding="utf-8") as f:
        store = json.load(f)
    table = store.setdefault("tables", {}).setdefault("workspaces", {})

    src = next((k for k, v in table.items() if os.path.normcase(v.get("path", "")) == os.path.normcase(old)), None)
    dst = next((k for k, v in table.items() if os.path.normcase(v.get("path", "")) == os.path.normcase(new)), None)

    if not src:
        print("! workspace.json 里找不到旧工作区，跳过索引迁移（可能已经改过）")
    else:
        print(f"索引：workspace {src}")
        print(f"  会话 {table[src].get('sessionIds')}")
        if dst:
            print(f"  已存在同名目标 workspace {dst}，将合并后删除重复项")
        else:
            print(f"  目标 workspace 不存在，将复用旧条目并改 path")

    # 1) 会话目录
    src_sess_dir = os.path.join(SESSIONS, old_dir)
    dst_sess_dir = os.path.join(SESSIONS, new_dir)
    moved = []
    if os.path.isdir(src_sess_dir):
        os.makedirs(dst_sess_dir, exist_ok=True)
        for name in os.listdir(src_sess_dir):
            p = os.path.join(src_sess_dir, name)
            if not os.path.isdir(p):
                continue
            target = os.path.join(dst_sess_dir, name)
            print(f"  会话 {name} -> {dst_sess_dir}")
            if args.apply:
                if os.path.exists(target):
                    print("    ! 目标已存在，跳过")
                    continue
                shutil.move(p, target)
            moved.append(target if args.apply else p)
        if args.apply and not os.listdir(src_sess_dir):
            os.rmdir(src_sess_dir)
            print("  旧会话目录已清空并删除")
    else:
        print(f"  旧会话目录不存在：{src_sess_dir}（可能已迁移）")

    # 2) 首行 cwd
    for d in moved:
        f = os.path.join(d, "session.v4.jsonl.zstd")
        if os.path.exists(f):
            print(f"  修 cwd: {os.path.basename(d)}")
            patch_cwd(f, new, args.apply)

    # 3) workspace.json
    if src:
        entry = table.pop(src)
        entry["path"] = new
        entry["title"] = os.path.basename(new)
        entry["sessionIds"] = sorted(set(entry.get("sessionIds", []) + (table[dst].get("sessionIds", []) if dst else [])))
        if dst:
            table.pop(dst)
        if args.apply:
            table[src] = entry
            ids = store.setdefault("global", {}).setdefault("workspaceIds", [])
            ids[:] = sorted({i for i in ids if i != dst} | {src})
            shutil.copy2(STORES, STORES + ".bak")
            with open(STORES, "w", encoding="utf-8") as f:
                json.dump(store, f, ensure_ascii=False, indent=2)
        print(f"  索引 -> path={new}, 会话 {entry['sessionIds']}")

    print("\n完成。" if args.apply else "\n预览结束，加 --apply 执行。")
    if args.apply:
        print("下一步：用 DSH 打开新工作区，历史会话应该还在。")


if __name__ == "__main__":
    main()
