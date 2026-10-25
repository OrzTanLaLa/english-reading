"""一次调用就让模型按页分块输出（<<<PAGE1>>> / <<<PAGE2>>> 标记）。

目标：不裁剪、不分割，靠提示词拿到「每页独立文本」。
在单页图（thumb_3）和跨页图（thumb_5）上验证标记是否稳定出现、内容是否串页。
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ocr_models import metrics, words  # noqa: E402
from prompt_ab import ask  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / "artifacts/b2-final/reference.txt"
OUT_DIR = ROOT / "artifacts/b2-final/prompt-ab"

PROMPT = (
    "逐字转写这张照片里的英文文字，只输出图片中真实存在的字符。\n"
    "严禁改写、补全、翻译或猜测：看不清的字符用 [?] 表示。\n"
    "这张照片可能是摊开的书，画面里可能有一页或两页文字。请按页分别输出，格式严格如下：\n"
    "<<<PAGE1>>>\n（第一页/相对左侧那一页的正文，按阅读顺序，段落之间空一行）\n"
    "<<<PAGE2>>>\n（第二页/相对右侧那一页的正文；如果画面里只有一页，这一行整段省略）\n"
    "不要输出任何其他说明文字、坐标或结构化标记。"
)

LEFT_MARK = ["foolish or stupid", "radio or watching", "Bangor"]
RIGHT_MARK = ["living, breathing", "12 There", "13 So, no matter", "wurfing"]


def split_pages(text: str) -> list[str]:
    parts = re.split(r"<<<PAGE(\d+)>>>", text)
    pages = []
    for i in range(1, len(parts), 2):
        pages.append(parts[i + 1].strip())
    return pages


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", default=[str(ROOT / "artifacts/b2-final/thumb_3.jpg"),
                                                    str(ROOT / "artifacts/b2-final/thumb_5.jpg")])
    args = ap.parse_args()
    ref_words = words(REF.read_text(encoding="utf-8"))
    for img_path in args.images:
        img = Path(img_path)
        name = img.stem
        text = ask("qwen3-vl-plus", img, PROMPT, timeout=180)
        (OUT_DIR / f"{name}__F_分页标记.txt").write_text(text, encoding="utf-8")
        pages = split_pages(text)
        print(f"===== {name}: 解析出 {len(pages)} 页")
        for i, page in enumerate(pages, 1):
            m = metrics(ref_words, words(page))
            has_left = [k for k in LEFT_MARK if k in page]
            has_right = [k for k in RIGHT_MARK if k in page]
            print(f"  页{i}: {len(words(page))} 词 prec={m['precision']:.3f} "
                  f"左页特征={has_left or '无'} 右页特征={has_right or '无'}")


if __name__ == "__main__":
    main()
