"""提示词 A/B：让视觉模型自己「只读一页」，不靠裁剪。

在跨页照片上对比四种提示策略，用原文算精确率/F1：
  A 基线      —— 现有严格转写提示
  B 指定左页  —— 明确告诉它「这是摊开的书，只转写左页」
  C 自判主页  —— 让它先判断哪页是主体，只转写那页
  D 两段式    —— 先让它描述版面再有针对性地转写

用法：python scripts/prompt_ab.py --images a.jpg b.jpg --model qwen3-vl-plus
"""

import argparse
import base64
import concurrent.futures as cf
import json
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare_ocr_models import CONFIG, ENDPOINT, metrics, words  # noqa: E402

sys.stdout.reconfigure(encoding="utf-8")

BASE = (
    "逐字转写这张图片里的英文文字，只输出图片中真实存在的字符。\n"
    "严禁改写、补全、翻译或猜测：看不清的字符用 [?] 表示，看不清的整行直接跳过。\n"
    "按阅读顺序输出，段落之间空一行。不要输出任何说明文字。\n"
    "只输出文字本身：绝对不要输出坐标、方框数字、JSON、Markdown 表格或任何结构化标记。"
)

PROMPTS = {
    "A_基线": BASE,
    "B_指定左页": BASE + "\n这张照片是一本摊开的书，画面里可能同时有两页。**只转写左页**的正文，完全忽略右页的文字。",
    "C_自判主页": BASE + "\n先判断画面里有几页。如果有多页，只转写**面积最大、正文最多**的那一页，忽略其他页。",
    "D_先描述后转写": None,  # 两段式，见下
}

DESCRIBE = (
    "这张照片是一本摊开的书的页面。用一句话说明：画面里能看到几页文字？每页大致在画面的什么位置（左/中/右）？"
    "只回答这一句，不要转写正文。"
)
TRANSCRIBE_LEFT = BASE + "\n根据上文描述，**只转写位于左侧的那一页**，忽略其他页。"


def api_key() -> str:
    return json.loads(CONFIG.read_text(encoding="utf-8"))["cosyvoice"]["api_key"]


def ask(model: str, image_path: Path, prompt: str, timeout: int = 120) -> str:
    data = base64.b64encode(image_path.read_bytes()).decode("ascii")
    mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
    body = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}},
                {"type": "text", "text": prompt},
            ],
        }],
    }
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key()}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"]


def run_variant(model: str, image: Path, name: str) -> tuple[str, str, float]:
    t0 = time.time()
    try:
        if PROMPTS[name] is None:
            desc = ask(model, image, DESCRIBE)
            text = ask(model, image, TRANSCRIBE_LEFT)
            text = f"[描述] {desc.strip()}\n\n{text}"
        else:
            text = ask(model, image, PROMPTS[name])
        return name, text, time.time() - t0
    except Exception as e:  # noqa: BLE001
        return name, f"[FAILED] {type(e).__name__}: {e}", time.time() - t0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--model", default="qwen3-vl-plus")
    ap.add_argument("--ref", default=str(Path(__file__).resolve().parents[1] / "artifacts/b2-final/reference.txt"))
    ap.add_argument("--save-dir", default=str(Path(__file__).resolve().parents[1] / "artifacts/b2-final/prompt-ab"))
    args = ap.parse_args()

    ref_words = words(Path(args.ref).read_text(encoding="utf-8"))
    out_dir = Path(args.save_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(Path(i), name) for i in args.images for name in PROMPTS]
    results = []
    with cf.ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(run_variant, args.model, img, name): (img, name) for img, name in jobs}
        for fut in cf.as_completed(futures):
            img, name = futures[fut]
            results.append((*fut.result(), img))

    for name, text, secs, img in sorted(results, key=lambda r: (r[3].name, r[0])):
        if text.startswith("[FAILED]"):
            print(f"{img.name:16} {name:12} {secs:5.1f}s {text[:70]}")
            continue
        m = metrics(ref_words, words(text))
        (out_dir / f"{img.stem}__{name}.txt").write_text(text, encoding="utf-8")
        first = text.splitlines()[0][:60] if text.splitlines() else ""
        print(f"{img.name:16} {name:12} {secs:5.1f}s prec={m['precision']:.3f} "
              f"matched={m['matched']:>4}/{m['out']:<4} F1={m['f1']:.3f}  首行: {first}")


if __name__ == "__main__":
    main()
