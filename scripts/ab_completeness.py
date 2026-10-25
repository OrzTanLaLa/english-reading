"""让视觉模型判断每一页是否完整入镜（用于自动取舍/提醒补拍）。

对每张图问：画面里有几页、各在什么位置、是否完整可见、大约露出多少。
输出 JSON，便于程序解析。

用法：python scripts/ab_completeness.py --images a.jpg b.jpg --model qwen3-vl-plus
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prompt_ab import ask  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]

PROMPT = (
    "这是一张拍摄书籍页面的照片，可能拍到一页或两页。请判断画面中出现了哪些页面、各自是否完整。\n"
    "只输出 JSON，不要任何解释文字，格式：\n"
    "{\"pages\": [{\"position\": \"left|right|full\", \"complete\": true|false, "
    "\"visible_ratio\": 0-100 的整数, \"cut_edges\": [\"left|right|top|bottom\"], "
    "\"reason\": \"一句话中文说明\"}]}\n"
    "判定标准：complete=true 表示整页四边都在画面内、没有被裁掉；只露出一部分（例如对页只露一条边）"
    "或某条边被裁掉，都算 false。visible_ratio 是这一页大约露出多少（100=整页）。\n"
    "如果画面里只有一页，pages 里就只有一项，position 填 full。"
)


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
        raw = text.strip()
        body = raw[raw.find("{"): raw.rfind("}") + 1] if "{" in raw else raw
        print(f"===== {p.name}")
        try:
            data = json.loads(body)
            for page in data.get("pages", []):
                print(f"  {page.get('position'):6} complete={page.get('complete')!s:5} "
                      f"visible={page.get('visible_ratio')}% cut={page.get('cut_edges')} "
                      f"| {page.get('reason')}")
        except json.JSONDecodeError:
            print("  (无法解析) " + raw[:200])


if __name__ == "__main__":
    main()
