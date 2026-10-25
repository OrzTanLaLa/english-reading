"""B2 五页实测报告：逐页打印几何统计 + 恢复后的正文，用于人工判断段落顺序。

正文来自 App 侧 core/layout.ts 的输出（ocr_layout_N.txt），几何统计来自原始 JSON。

用法：python scripts/report_b2_pages.py
"""

import json
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
PAGES = ROOT / "artifacts" / "b2-pages"


def main() -> None:
    total_lines = 0
    for i in range(1, 6):
        jp = PAGES / f"ocr_probe_{i}.json"
        tp = PAGES / f"ocr_layout_{i}.txt"
        if not jp.exists() or not tp.exists():
            print(f"缺少第 {i} 页数据")
            continue

        d = json.loads(jp.read_text(encoding="utf-8"))
        lines = d["lines"]
        total_lines += len(lines)

        w, h = d["w"], d["h"]
        x0 = min(l["x0"] for l in lines)
        x1 = max(l["x1"] for l in lines)
        widths = sorted(l["x1"] - l["x0"] for l in lines)
        edge = [l for l in lines if l["x0"] <= w * 0.02 or l["x1"] >= w * 0.98]

        print("=" * 78)
        print(f"第 {i} 页  {w}x{h}  OCR {d['ms']}ms  blocks={d['blocks']}  lines={len(lines)}")
        print(f"  文字区 x=[{x0},{x1}]  最窄行={widths[0]}px  中位行宽={widths[len(widths) // 2]}px")
        print(f"  贴边行（x0≤2% 或 x1≥98% 图宽）: {len(edge)} 行"
              + (f"  例: {[l['v'][:10] for l in edge[:3]]}" if edge else ""))
        print("=" * 78)
        print(tp.read_text(encoding="utf-8"))
        print()

    print(f"合计 {total_lines} 行")


if __name__ == "__main__":
    main()
