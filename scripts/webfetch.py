#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
抓取「没有 llms.txt」的文档站，把 HTML 正文抽成纯文本。

背景：DeepSeek 的 api-docs 没有 llms.txt（/llms.txt 返回的是 SPA 壳页，和 404 页一样），
但页面是**服务端渲染**的，抓 HTML 后剥掉标签就能拿到正文——实测能拿到 2.3 万字、
max_tokens / tool_calls 等参数表都在。

用法：
    python scripts/webfetch.py https://api-docs.deepseek.com/zh-cn/api/create-chat-completion
    python scripts/webfetch.py <url> --grep tool_calls --grep max_tokens
    python scripts/webfetch.py <url> --save docs/vendor/deepseek-chat.md
"""
import argparse
import html
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fetch(url: str, timeout: int = 40) -> str:
    req = urllib.request.Request(url, headers={"user-agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    return raw.decode("utf-8", "replace")


def html_to_text(src: str) -> str:
    # 导航/侧栏通常是 <nav>，脚本样式整体丢掉
    body = re.sub(r"<script[\s\S]*?</script>", " ", src, flags=re.I)
    body = re.sub(r"<style[\s\S]*?</style>", " ", body, flags=re.I)
    body = re.sub(r"<nav[\s\S]*?</nav>", " ", body, flags=re.I)
    body = re.sub(r"<footer[\s\S]*?</footer>", " ", body, flags=re.I)
    # 块级元素换行，避免全挤成一行
    body = re.sub(r"</(p|div|li|tr|h[1-6]|pre|table|section)>", "\n", body, flags=re.I)
    body = re.sub(r"<br\s*/?>", "\n", body, flags=re.I)
    body = re.sub(r"<[^>]+>", " ", body)
    body = html.unescape(body)
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in body.splitlines()]
    out = []
    blank = 0
    for ln in lines:
        if ln == "":
            blank += 1
            if blank > 1:
                continue
        else:
            blank = 0
        out.append(ln)
    return "\n".join(out).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--grep", action="append", default=[], help="只打印命中这些关键词的段落")
    ap.add_argument("--save", default="", help="另存到文件（相对仓库根）")
    ap.add_argument("--chars", type=int, default=0, help="只打印前 N 个字符")
    args = ap.parse_args()

    text = html_to_text(fetch(args.url))
    print(f"# {args.url}\n# 正文 {len(text)} 字符\n")

    if args.grep:
        paras = [p for p in text.split("\n\n") if any(k in p for k in args.grep)]
        print("\n\n".join(paras)[: args.chars or 20000])
    else:
        print(text[: args.chars] if args.chars else text)

    if args.save:
        path = args.save if os.path.isabs(args.save) else os.path.join(ROOT, args.save)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {args.url}\n\n{text}")
        print(f"\n已保存 {path}", file=sys.stderr)


if __name__ == "__main__":
    main()
