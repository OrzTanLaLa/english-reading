"""用 Qwen-VL 整页解析课本照片，验证「云侧现成接口能否替代自研版面算法」。

输入一张图片，输出模型给出的阅读顺序文本。费用按 token 计，单页约 1-2 分钱。

用法：python scripts/qwen_vl_probe.py artifacts/b2-final/thumb_1.jpg [模型名]
"""

import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "validation" / "B0A" / "config.json"
ENDPOINT = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

PROMPT = (
    "这是一页英语课本的照片，画面里可能同时拍到相邻的另一页，也可能有笔记或批注。\n"
    "请只输出你要读的那一页（画面主体、正文最多的那一页）的课文正文：\n"
    "1. 按正确的阅读顺序（从左到右、从上到下，遇到分栏先读完左栏再读右栏）；\n"
    "2. 保留段落分隔，段落之间空一行；\n"
    "3. 忽略相邻页的文字、页码、页眉页脚、手写笔记；\n"
    "4. 不要翻译、不要解释、不要添加任何说明文字。"
)

PROMPT_STRICT = (
    "逐字转写这张图片里的英文文字，只输出图片中真实存在的字符。\n"
    "严禁改写、补全、翻译或猜测：看不清的字符用 [?] 表示，看不清的整行直接跳过。\n"
    "如果图片里的文字是旋转或倒置的，先在心里转正再逐行转写。\n"
    "按阅读顺序输出，段落之间空一行。不要输出任何说明文字。"
)


def api_key() -> str:
    d = json.loads(CONFIG.read_text(encoding="utf-8"))
    return d["cosyvoice"]["api_key"]


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("用法: python scripts/qwen_vl_probe.py <图片路径> [模型名]")
    image_path = Path(sys.argv[1])
    model = sys.argv[2] if len(sys.argv) > 2 else "qwen-vl-ocr"
    strict = len(sys.argv) > 3 and sys.argv[3] == "strict"
    prompt = PROMPT_STRICT if strict else PROMPT

    data = base64.b64encode(image_path.read_bytes()).decode("ascii")
    mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
    }

    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key()}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}")
        print(e.read().decode("utf-8", "replace")[:800])
        raise SystemExit(1)

    print(f"model={payload.get('model')}  usage={payload.get('usage')}")
    print("-" * 70)
    print(payload["choices"][0]["message"]["content"])


if __name__ == "__main__":
    main()
