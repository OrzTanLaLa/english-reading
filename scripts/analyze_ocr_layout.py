"""分析真机 OCR 探针导出的逐行坐标，回答两件事：
1. 这张照片的版面是什么（单栏 / 双栏 / 跨页两页）
2. 用「行覆盖 + 垂直空白带」能不能找到书脊沟 / 栏间沟

用法：python scripts/analyze_ocr_layout.py [json路径]
"""

import json
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "artifacts" / "ocr-probe-real.json"


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def column_profile(lines: list[dict], width: int, step: int = 4) -> list[int]:
    """把每行的 x 区间打到像素柱上，返回每列的覆盖计数。"""
    bins = [0] * (width // step + 1)
    for line in lines:
        for x in range(line["x0"], line["x1"], step):
            bins[min(x // step, len(bins) - 1)] += 1
    return bins


def gaps(bins: list[int], step: int) -> list[tuple[int, int]]:
    """找出覆盖为 0 的连续区段（像素区间）。"""
    out = []
    start = None
    for i, v in enumerate(bins):
        if v == 0 and start is None:
            start = i
        elif v != 0 and start is not None:
            if (i - start) * step >= 20:
                out.append((start * step, i * step))
            start = None
    if start is not None and (len(bins) - start) * step >= 20:
        out.append((start * step, len(bins) * step))
    return out


def main() -> None:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    d = load(path)
    w, h = d["w"], d["h"]
    lines = d["lines"]
    print(f"图片: {path.name}  {w}x{h}  OCR {d['ms']} ms  blocks={d['blocks']}  lines={len(lines)}")
    print(f"value 字符数: {len(d['value'])}")

    # 按 y 排序，看行高与行距
    ordered = sorted(lines, key=lambda l: (l["y0"], l["x0"]))
    heights = sorted(set(l["y1"] - l["y0"] for l in ordered))
    print(f"行高分布(px): {heights[:12]}")

    bins = column_profile(lines, w)
    gs = gaps(bins, 4)
    print(f"\n垂直空白带（x 像素区间, ≥20px）: {gs}")
    left_margin = ordered[0]["x0"] if ordered else 0
    right_margin = max(l["x1"] for l in ordered) if ordered else w
    print(f"文字左右边界: {left_margin} .. {right_margin}（图宽 {w}）")

    # 判据：中间存在一条 ≥40px 的空白带，且两侧都有相当多行 → 认为分成了两栏/两页
    print("\n按块看（块内首行 + 块包围盒）:")
    for b in range(d["blocks"]):
        bl = [l for l in lines if l["b"] == b]
        if not bl:
            continue
        x0 = min(l["x0"] for l in bl)
        x1 = max(l["x1"] for l in bl)
        y0 = min(l["y0"] for l in bl)
        y1 = max(l["y1"] for l in bl)
        print(f"  b{b:<2} lines={len(bl):<2} box=({x0},{y0})-({x1},{y1}) w={x1 - x0:<4} 首行: {bl[0]['v'][:55]}")

    print("\n按 y 排序的前 20 行:")
    for l in ordered[:20]:
        print(f"  y={l['y0']:<5} x=[{l['x0']:<5},{l['x1']:<5}] b{l['b']:<2} {l['v'][:70]}")


if __name__ == "__main__":
    main()
