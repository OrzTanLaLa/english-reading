"""版面算法原型：从 OCR 的逐行坐标恢复阅读顺序，并丢弃对页残片。

在真机数据（artifacts/ocr-probe-real.json）上验证思路，跑通后再照此移植到
app/entry/src/main/ets/core/layout.ts。

三个步骤：
1. 按 x 区间聚类成「文字列」（cluster）
2. 丢弃贴图像边缘、且明显窄于主文字列的碎片（对页残留）
3. 对剩余文字做 XY-cut：先横向切段（y 空白带），再段内纵向切栏（x 空白带）

用法：python scripts/layout_probe.py [json路径]
"""

import json
import sys
from dataclasses import dataclass
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = ROOT / "artifacts" / "ocr-probe-real.json"


@dataclass
class Line:
    text: str
    x0: int
    y0: int
    x1: int
    y1: int

    @property
    def w(self) -> int:
        return self.x1 - self.x0

    @property
    def h(self) -> int:
        return self.y1 - self.y0

    @property
    def yc(self) -> float:
        return (self.y0 + self.y1) / 2


def load_lines(path: Path) -> tuple[int, int, list[Line]]:
    d = json.loads(path.read_text(encoding="utf-8"))
    lines = [Line(l["v"], l["x0"], l["y0"], l["x1"], l["y1"]) for l in d["lines"]]
    return d["w"], d["h"], lines


def cluster_columns(lines: list[Line], tol: int) -> list[list[Line]]:
    """按 x 区间是否重叠把行聚成列。区间有交集（留 tol 余量）就并到一组。"""
    cols: list[list[Line]] = []
    for line in sorted(lines, key=lambda l: l.x0):
        placed = False
        for col in cols:
            if line.x0 <= max(c.x1 for c in col) + tol:
                col.append(line)
                placed = True
                break
        if not placed:
            cols.append([line])
    # 合并后可能出现「桥接」把两列并成一列，这里简单迭代收敛一次
    merged = True
    while merged:
        merged = False
        for i in range(len(cols)):
            for j in range(i + 1, len(cols)):
                a = (min(c.x0 for c in cols[i]), max(c.x1 for c in cols[i]))
                b = (min(c.x0 for c in cols[j]), max(c.x1 for c in cols[j]))
                if a[0] <= b[1] + tol and b[0] <= a[1] + tol:
                    cols[i] = cols[i] + cols[j]
                    del cols[j]
                    merged = True
                    break
            if merged:
                break
    return cols


def drop_edge_slivers(cols: list[list[Line]], img_w: int, img_h: int) -> tuple[list[Line], list[list[Line]]]:
    """丢掉贴着图像左右边缘、且明显比主列窄的碎片。返回 (保留的行, 被丢的列)。"""
    if not cols:
        return [], []
    widths = [max(c.x1 for c in col) - min(c.x0 for c in col) for col in cols]
    main_w = max(widths)
    kept: list[Line] = []
    dropped: list[list[Line]] = []
    for col, w in zip(cols, widths):
        x0 = min(c.x0 for c in col)
        x1 = max(c.x1 for c in col)
        y0 = min(c.y0 for c in col)
        y1 = max(c.y1 for c in col)
        touches_left = x0 <= img_w * 0.02
        touches_right = x1 >= img_w * 0.98
        narrow = w < main_w * 0.3
        covers_height = (y1 - y0) > img_h * 0.15
        if (touches_left or touches_right) and narrow and covers_height:
            dropped.append(col)
        else:
            kept.extend(col)
    return kept, dropped


def h_bands(lines: list[Line], gap: int) -> list[list[Line]]:
    """按 y 方向空白带切段。"""
    bands: list[list[Line]] = []
    for line in sorted(lines, key=lambda l: l.y0):
        if bands and line.y0 - max(c.y1 for c in bands[-1]) <= gap:
            bands[-1].append(line)
        else:
            bands.append([line])
    return bands


def v_bands(lines: list[Line], gap: int) -> list[list[Line]]:
    """按 x 方向空白带切栏。"""
    bands: list[list[Line]] = []
    for line in sorted(lines, key=lambda l: l.x0):
        if bands and line.x0 - max(c.x1 for c in bands[-1]) <= gap:
            bands[-1].append(line)
        else:
            bands.append([line])
    return bands


def xy_cut(lines: list[Line], line_h: int, img_w: int, depth: int = 0) -> list[Line]:
    """先横切段、再纵向切栏；切不动就按 y 排。"""
    if len(lines) <= 1 or depth > 6:
        return sorted(lines, key=lambda l: (l.y0, l.x0))

    hs = h_bands(lines, gap=max(6, line_h // 2))
    if len(hs) > 1:
        out: list[Line] = []
        for band in hs:
            out.extend(xy_cut(band, line_h, img_w, depth + 1))
        return out

    vs = v_bands(lines, gap=max(10, int(img_w * 0.03)))
    if len(vs) > 1:
        out = []
        for band in vs:
            out.extend(xy_cut(band, line_h, img_w, depth + 1))
        return out

    return sorted(lines, key=lambda l: (l.y0, l.x0))


def main() -> None:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    img_w, img_h, lines = load_lines(path)
    print(f"原图 {img_w}x{img_h}，OCR {len(lines)} 行")

    heights = sorted(l.h for l in lines)
    line_h = heights[len(heights) // 2]
    tol = max(8, int(img_w * 0.01))

    cols = cluster_columns(lines, tol)
    print(f"聚类得到 {len(cols)} 列：")
    for i, col in enumerate(cols):
        x0 = min(c.x0 for c in col)
        x1 = max(c.x1 for c in col)
        print(f"  列{i}: {len(col):>2} 行 x=[{x0},{x1}] w={x1 - x0}")

    kept, dropped = drop_edge_slivers(cols, img_w, img_h)
    dropped_n = sum(len(c) for c in dropped)
    print(f"\n丢弃边缘碎片：{len(dropped)} 列 / {dropped_n} 行")
    for col in dropped:
        print(f"  丢: {[c.text[:12] for c in col[:4]]}")
    print(f"保留 {len(kept)} 行")

    ordered = xy_cut(kept, line_h, img_w)
    print("\n=== 恢复的阅读顺序 ===")
    for line in ordered:
        print(f"  y={line.y0:<5} x=[{line.x0:<5},{line.x1:<5}] {line.text}")


if __name__ == "__main__":
    main()
