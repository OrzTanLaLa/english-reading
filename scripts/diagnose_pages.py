"""逐页诊断：为什么版面分析没救回来。

打印三样东西：
1. 行宽/行高分布（判断照片是否被旋转 —— 行「又高又窄」说明文字是竖着的）
2. x 方向空白带（有没有栏间沟 / 书脊）
3. 每块的行数、包围盒、首行

用法：python scripts/diagnose_pages.py 3 4 5
"""

import json
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
PAGES = ROOT / "artifacts" / "b2-pages"


def load(i: int):
    return json.loads((PAGES / f"ocr_probe_{i}.json").read_text(encoding="utf-8"))


def gaps(lines, width, step=4):
    bins = [0] * (width // step + 2)
    for l in lines:
        for x in range(max(0, l["x0"]), min(width, l["x1"]), step):
            bins[x // step] += 1
    out, start = [], None
    for i, v in enumerate(bins):
        if v == 0 and start is None:
            start = i
        elif v != 0 and start is not None:
            if (i - start) * step >= 20:
                out.append((start * step, i * step))
            start = None
    if start is not None:
        out.append((start * step, len(bins) * step))
    return out


def main() -> None:
    pages = [int(a) for a in sys.argv[1:]] or [1, 2, 3, 4, 5]
    for i in pages:
        d = load(i)
        lines = d["lines"]
        w, h = d["w"], d["h"]
        ws = sorted(l["x1"] - l["x0"] for l in lines)
        hs = sorted(l["y1"] - l["y0"] for l in lines)
        print("=" * 70)
        print(f"第 {i} 页 {w}x{h}  lines={len(lines)} blocks={d['blocks']}")
        print(f"  行宽: min={ws[0]} 中位={ws[len(ws)//2]} max={ws[-1]}")
        print(f"  行高: min={hs[0]} 中位={hs[len(hs)//2]} max={hs[-1]}")
        print(f"  竖窄行(宽<2×中位行高)占比: {sum(1 for x in ws if x < 2*hs[len(hs)//2])/len(ws):.0%}")
        print(f"  x 空白带: {gaps(lines, w)}")
        by_block = {}
        for l in lines:
            by_block.setdefault(l["b"], []).append(l)
        for b, bl in sorted(by_block.items()):
            x0 = min(l["x0"] for l in bl)
            x1 = max(l["x1"] for l in bl)
            y0 = min(l["y0"] for l in bl)
            y1 = max(l["y1"] for l in bl)
            print(f"  b{b:<2} n={len(bl):<2} box=({x0},{y0})-({x1},{y1}) w={x1-x0:<4} {bl[0]['v'][:40]}")


if __name__ == "__main__":
    main()
