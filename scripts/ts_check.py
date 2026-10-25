#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用音频能量检验 TTS 词级时间戳是否准确。

思路：
  1. 把 PCM 切成 10ms 帧，算 RMS 包络；
  2. 用能量阈值得到「有声/无声」掩码；
  3. 用时间戳得到「应该有声」的掩码（词区间内为 1）；
  4. 在 -600..+600ms 内滑动，取两个掩码相关度最高的位移，
     该位移就是「时间戳相对音频」的系统偏移。

用法：
    python ts_check.py <pcm> <words.json>
"""
import json
import sys
import wave

import numpy as np

HOP_MS = 10


def load_pcm(path):
    with open(path, "rb") as f:
        raw = f.read()
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    # TTS 输出是单声道 16k
    return data


def envelope(samples, sr=16000, hop_ms=HOP_MS):
    hop = int(sr * hop_ms / 1000)
    n = len(samples) // hop
    trimmed = samples[: n * hop].reshape(n, hop)
    rms = np.sqrt(np.mean(trimmed ** 2, axis=1))
    return rms


def main():
    pcm_path, words_path = sys.argv[1], sys.argv[2]
    samples = load_pcm(pcm_path)
    sr = 16000
    dur_ms = len(samples) / sr * 1000
    rms = envelope(samples, sr)
    frames = len(rms)

    with open(words_path, encoding="utf-8") as f:
        raw_words = json.load(f)
    # 服务端字段是 begin_time/end_time，归一化一下
    words = [{"text": w["text"],
              "begin": w.get("begin", w.get("begin_time", 0)),
              "end": w.get("end", w.get("end_time", 0))} for w in raw_words]

    # 有声掩码：阈值取 20% 分位与最大值的中间
    thr = np.percentile(rms, 20) + 0.15 * (rms.max() - np.percentile(rms, 20))
    speech = (rms > thr).astype(np.float32)

    # 时间戳掩码
    ts_mask = np.zeros(frames, dtype=np.float32)
    for w in words:
        a = int(w["begin"] / HOP_MS)
        b = min(frames, int(w["end"] / HOP_MS))
        ts_mask[max(0, a):max(0, b)] = 1.0

    best_lag, best_corr = 0, -1.0
    for lag in range(-60, 61):  # ±600ms
        shifted = np.roll(ts_mask, lag)
        corr = float(np.dot(shifted, speech) / (np.linalg.norm(shifted) * np.linalg.norm(speech) + 1e-9))
        if corr > best_corr:
            best_corr, best_lag = corr, lag

    lead_silence = 0
    for i, v in enumerate(rms):
        if v > thr:
            lead_silence = i * HOP_MS
            break

    print(f"音频 {dur_ms:.0f} ms，词 {len(words)} 个")
    print(f"首个有声帧 {lead_silence} ms（音频开头的静音）")
    print(f"最佳对齐位移 {best_lag * HOP_MS:+d} ms（相关度 {best_corr:.3f}）")
    print("  正值 = 时间戳比音频晚，高亮会滞后；负值 = 时间戳偏早，高亮会提前")

    # 逐词起始点对拍：在 begin 附近找能量上升沿，算偏差
    print("\n逐词起始偏差（正=时间戳晚于真实起点）:")
    d_energy = np.diff(rms)
    deltas = []
    for w in words:
        b = int(w["begin"] / HOP_MS)
        lo, hi = max(1, b - 15), min(frames - 1, b + 15)
        if hi <= lo:
            continue
        k = lo + int(np.argmax(d_energy[lo:hi]))
        delta = (k - b) * HOP_MS
        deltas.append((w["text"].strip(), w["begin"], delta))
    for t, b, d in deltas:
        print(f"  {t!r:18} begin={b:>5}  能量上升沿偏差 {d:+4d} ms")
    if deltas:
        print(f"  平均偏差 {np.mean([d for _, _, d in deltas]):+.0f} ms，绝对均值 {np.mean([abs(d) for _, _, d in deltas]):.0f} ms")

    print("\n前 6 个词的区间能量（判断词边界是否落在语音上）:")
    for w in words[:6]:
        a = int(w["begin"] / HOP_MS)
        b = max(a + 1, min(frames, int(w["end"] / HOP_MS)))
        seg = rms[a:b]
        print(f"  {w['text']!r:16} {w['begin']:>5}-{w['end']:>5} ms  平均 RMS {seg.mean():.4f}  峰值 {seg.max():.4f}")

    # 词间停顿检测：时间戳里 end->next begin 的间隙，和能量谷是否重合
    gaps = []
    for i in range(1, len(words)):
        g0, g1 = words[i - 1]["end"], words[i]["begin"]
        if g1 - g0 >= 60:
            gaps.append((g0, g1))
    print(f"\n>=60ms 的词间间隙: {len(gaps)} 处")
    for g0, g1 in gaps[:6]:
        a, b = int(g0 / HOP_MS), int(g1 / HOP_MS)
        seg = rms[a:b]
        print(f"  {g0}-{g1} ms 间隙内 RMS 均值 {seg.mean():.4f}（低=确实是停顿）")


if __name__ == "__main__":
    main()
