"""同一批照片上对比多个 OCR/VLM 模型，用原文算出可比的指标。

并发版：每个 (模型, 图片) 一个线程，独立超时与重试，整体耗时约等于最慢的那个。

指标：
  precision   —— 输出词里能在原文中【按顺序】对齐的比例（错字/幻觉/乱序都会拉低）
  recall_art  —— 对齐词数 / 原文总词数（用于横向比较覆盖量）
  F1          —— 两者调和平均
  order       —— 输出里段落编号序列

用法：
  python scripts/compare_ocr_models.py --images a.jpg b.jpg --models m1 m2 --workers 6
"""

import argparse
import base64
import concurrent.futures as cf
import difflib
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "validation" / "B0A" / "config.json"
ENDPOINT = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

PROMPT = (
    "逐字转写这张图片里的英文文字，只输出图片中真实存在的字符。\n"
    "严禁改写、补全、翻译或猜测：看不清的字符用 [?] 表示，看不清的整行直接跳过。\n"
    "如果图片里的文字是旋转或倒置的，先在心里转正再逐行转写。\n"
    "按阅读顺序输出，段落之间空一行。不要输出任何说明文字。\n"
    "只输出文字本身：绝对不要输出坐标、方框数字、JSON、Markdown 表格或任何结构化标记。"
)


def api_key() -> str:
    return json.loads(CONFIG.read_text(encoding="utf-8"))["cosyvoice"]["api_key"]


def normalize(text: str) -> str:
    text = text.replace("—", "-").replace("–", "-")
    text = text.replace("“", '"').replace("”", '"').replace("‘", "'").replace("’", "'")
    return re.sub(r"\s+", " ", text).strip()


def words(text: str) -> list[str]:
    return re.findall(r"[A-Za-z0-9']+", normalize(text).lower())


def call_once(model: str, image_path: Path, timeout: int) -> str:
    data = base64.b64encode(image_path.read_bytes()).decode("ascii")
    mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
    body = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}},
                {"type": "text", "text": PROMPT},
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


def call(model: str, image_path: Path, timeout: int, retries: int) -> tuple[str, float]:
    t0 = time.time()
    last = ""
    for attempt in range(retries + 1):
        try:
            return call_once(model, image_path, timeout), time.time() - t0
        except Exception as e:  # 网络/超时都走这里
            last = f"{type(e).__name__}: {e}"
            if attempt < retries:
                continue
    return f"[FAILED] {last}", time.time() - t0


def metrics(ref_words: list[str], out_words: list[str]) -> dict:
    sm = difflib.SequenceMatcher(None, ref_words, out_words, autojunk=False)
    matched = sum(b.size for b in sm.get_matching_blocks())
    precision = matched / len(out_words) if out_words else 0.0
    recall = matched / len(ref_words) if ref_words else 0.0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    return {"matched": matched, "out": len(out_words), "precision": precision, "recall": recall, "f1": f1}


def order_of(text: str) -> str:
    nums = []
    for line in text.splitlines():
        m = re.match(r"\s*(\d{1,2})[\s.]", line)
        if m:
            n = int(m.group(1))
            if 1 <= n <= 20 and (not nums or n != nums[-1]):
                nums.append(n)
    return ",".join(str(n) for n in nums) if nums else "(无编号)"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--ref", default=str(ROOT / "artifacts/b2-final/reference.txt"))
    ap.add_argument("--save-dir", default=str(ROOT / "artifacts/b2-final/model-outputs"))
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--retries", type=int, default=1)
    args = ap.parse_args()

    ref_words = words(Path(args.ref).read_text(encoding="utf-8"))
    out_dir = Path(args.save_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    jobs = [(m, Path(i)) for m in args.models for i in args.images]
    t0 = time.time()
    results = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(call, m, p, args.timeout, args.retries): (m, p) for m, p in jobs}
        for fut in cf.as_completed(futures):
            model, path = futures[fut]
            text, secs = fut.result()
            results.append((model, path, text, secs))

    for model, path, text, secs in sorted(results, key=lambda r: (r[0], r[1].name)):
        if text.startswith("[FAILED]"):
            print(f"{model:24} {path.name:16} {secs:5.1f}s  {text[:90]}")
            continue
        m = metrics(ref_words, words(text))
        (out_dir / f"{model.replace('/', '_')}__{path.stem}.txt").write_text(text, encoding="utf-8")
        print(f"{model:24} {path.name:16} {secs:5.1f}s  prec={m['precision']:.3f} "
              f"matched={m['matched']:>4}/{m['out']:<4} F1={m['f1']:.3f} order={order_of(text)}")

    if results:
        print("\n===== 汇总 =====")
        by_model: dict[str, list[tuple[float, float]]] = {}
        for model, _, text, _ in results:
            if text.startswith("[FAILED]"):
                continue
            m = metrics(ref_words, words(text))
            by_model.setdefault(model, []).append((m["precision"], m["f1"]))
        for model, vals in sorted(by_model.items(), key=lambda kv: -sum(v[1] for v in kv[1]) / len(kv[1])):
            mp = sum(v[0] for v in vals) / len(vals)
            mf = sum(v[1] for v in vals) / len(vals)
            print(f"{model:24} 平均精确率 {mp:.3f}  平均F1 {mf:.3f}  ({len(vals)} 张)")
    print(f"\n总耗时 {time.time() - t0:.1f}s（{len(jobs)} 个请求，并发 {args.workers}）")


if __name__ == "__main__":
    main()
