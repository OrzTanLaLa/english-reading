"""自动检测跨页书脊并把照片切成左右两页（纯几何，无人工）。

思路：
1. 灰度化 + 横向降采样
2. 统计每列「文字墨迹」像素数（暗且局部对比度高的像素，避免把阴影当文字）
3. 在中部区域找最深的低谷，要求低谷两侧都有足够墨迹、且谷深低于两侧的 60%
4. 命中就按谷中心切开，两半各留 2% 余量

用法：
  python scripts/split_spread.py --image artifacts/b2-final/thumb_5.jpg \
      --out-dir artifacts/b2-final/split [--debug]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.stdout.reconfigure(encoding="utf-8")


def ink_profile(gray: np.ndarray, target_w: int = 320) -> np.ndarray:
    """每列的文字墨迹强度（0..1）。局部对比度高且偏暗才算文字，纯阴影不算。"""
    h, w = gray.shape
    step = max(1, w // target_w)
    small = gray[:, ::step].astype(np.float32)

    # 局部均值（用横向滑窗近似），用来衡量局部对比度
    kernel = max(3, small.shape[1] // 100)
    pad = np.pad(small, ((0, 0), (kernel, kernel)), mode="edge")
    cum = np.cumsum(pad, axis=1)
    cum = np.concatenate([np.zeros((cum.shape[0], 1), dtype=cum.dtype), cum], axis=1)
    means = (cum[:, 2 * kernel + 1:] - cum[:, :-(2 * kernel + 1)]) / (2 * kernel + 1)

    dark = (small < 110) & (means - small > 25)  # 暗 + 明显低于周边
    return dark.mean(axis=0)


def find_gutter(profile: np.ndarray, min_gap_ratio: float = 0.02) -> tuple[int, float] | None:
    n = len(profile)
    lo, hi = int(n * 0.38), int(n * 0.68)
    if hi - lo < 10:
        return None

    # 平滑
    k = max(3, n // 200)
    smooth = np.convolve(profile, np.ones(k) / k, mode="same")

    best = None
    for i in range(lo, hi):
        left = smooth[max(0, i - n // 10):i]
        right = smooth[i + 1:min(n, i + n // 10)]
        if len(left) < 5 or len(right) < 5:
            continue
        # 两侧都要有实质文字（说明真的分成了两块）
        if left.max() < 0.02 or right.max() < 0.02:
            continue
        ref = min(left.max(), right.max())
        depth = 1.0 - smooth[i] / ref if ref > 0 else 0.0
        if depth <= 0:
            continue

        # 谷必须是一段连续的低墨迹区，而不是两个词之间的小缝
        width = 1
        j = i - 1
        while j >= 0 and smooth[j] < ref * 0.75:
            width += 1
            j -= 1
        j = i + 1
        while j < n and smooth[j] < ref * 0.75:
            width += 1
            j += 1
        min_width = max(4, n // 60)
        if width < min_width:
            continue

        if best is None or depth > best[1]:
            best = (i, depth)
    if best is None or best[1] < 0.62:
        return None
    return best


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    img = Image.open(args.image).convert("RGB")
    gray = np.asarray(img.convert("L"))
    prof = ink_profile(gray)

    hit = find_gutter(prof)
    if args.debug:
        n = len(prof)
        print(f"图片 {img.width}x{img.height}，降采样列数 {n}")
        for frac in (0.25, 0.35, 0.45, 0.5, 0.55, 0.65, 0.75):
            i = int(n * frac)
            print(f"  x={i:>1}/{n} ({frac:.0%}) 墨迹={prof[i]:.3f}")

    if hit is None:
        print(f"{Path(args.image).name}: 未检测到书脊，按单页处理")
        return

    idx, depth = hit
    x = int(idx / len(prof) * img.width)
    margin = int(img.width * 0.02)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stem = Path(args.image).stem
    img.crop((0, 0, max(1, x - margin), img.height)).save(out / f"{stem}_left.jpg", quality=92)
    img.crop((min(img.width - 1, x + margin), 0, img.width, img.height)).save(out / f"{stem}_right.jpg", quality=92)
    print(f"{Path(args.image).name}: 书脊在 x={x}（深度 {depth:.2f}，{x/img.width:.0%} 处）"
          f" → {stem}_left.jpg / {stem}_right.jpg")


if __name__ == "__main__":
    main()
