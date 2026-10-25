"""单次实验：让模型只转写跨页照片的右页，并检查是否混入左页内容。"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ocr_models import metrics, words  # noqa: E402
from prompt_ab import BASE, ask  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
IMG = ROOT / "artifacts/b2-final/thumb_5.jpg"
REF = ROOT / "artifacts/b2-final/reference.txt"
OUT = ROOT / "artifacts/b2-final/prompt-ab/thumb_5__E_指定右页.txt"

PROMPT = BASE + "\n这张照片是一本摊开的书，画面里有两页。**只转写右页的正文**，完全忽略左页的文字。"


def main() -> None:
    text = ask("qwen3-vl-plus", IMG, PROMPT)
    OUT.write_text(text, encoding="utf-8")
    m = metrics(words(REF.read_text(encoding="utf-8")), words(text))
    print(f"右页: prec={m['precision']:.3f} matched={m['matched']}/{m['out']}")
    lines = text.splitlines()
    print("首行:", lines[0][:90] if lines else "(空)")
    left_markers = ["foolish or stupid", "radio or watching", "Bangor", "Give me the 411"]
    print("混入左页内容:", [k for k in left_markers if k in text] or "无")


if __name__ == "__main__":
    main()
