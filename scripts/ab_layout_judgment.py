"""让模型做「是否旋转 / 每页段落是否完整」的分类判断（不要它给数值）。

输出 JSON：
  {"rotate": "none|90|180|270",
   "pages": [{"position": "left|right|full", "paragraph_complete": true|false, "note": "..."}]}

"段落完整" 的口径：正文首段和末段是自然收尾的完整句子，而不是半句话被截断；
即使页面边缘不在画面内，只要行距/段落间距正常、文字没有中途断掉，就算完整。

用法：python scripts/ab_layout_judgment.py --images a.jpg b.jpg
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prompt_ab import ask  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

PROMPT = (
    "这张照片拍的是一本书的页面，画面里可能有一页，也可能有两页。请判断三件事，只输出 JSON。\n"
    "1) rotate：需要把图片转正才能正常阅读吗？取值 none / 90 / 180 / 270，数字表示顺时针转多少度。\n"
    "2) pages：画面里每一页的位置（left / right / full），以及这一页的**正文段落**是否完整。\n"
    "   「段落完整」指正文的首段和末段都是自然收尾的完整句子，没有被截断成半句话；\n"
    "   即使页面边缘（页边距）不在画面里，只要文字按正常行距排列、段落正常结束，就算完整。\n"
    "   如果某页只露出很窄的一条、读不出完整段落，算不完整。\n"
    "3) note：每页一句话说明依据（可选）。\n"
    "不要输出百分比、面积、坐标或任何测量数值。\n"
    "JSON 格式：{\"rotate\": \"none\", \"pages\": [{\"position\": \"full\", "
    "\"paragraph_complete\": true, \"note\": \"\"}]}"
)


def parse(text: str) -> dict | None:
    raw = text.strip()
    start, end = raw.find("{"), raw.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        return json.loads(raw[start:end + 1])
    except json.JSONDecodeError:
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--model", default="qwen3-vl-plus")
    args = ap.parse_args()

    for img in args.images:
        p = Path(img)
        try:
            text = ask(args.model, p, PROMPT, timeout=120)
        except Exception as e:  # noqa: BLE001
            print(f"{p.name}: FAILED {type(e).__name__}: {e}")
            continue
        data = parse(text)
        print(f"===== {p.name}")
        if data is None:
            print("  (无法解析) " + text[:200])
            continue
        print(f"  rotate = {data.get('rotate')}")
        for page in data.get("pages", []):
            print(f"  {page.get('position'):6} 段落完整={page.get('paragraph_complete')!s:5} {page.get('note', '')}")


if __name__ == "__main__":
    main()
