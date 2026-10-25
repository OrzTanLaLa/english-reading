"""验证 words.db：抽样查询、课文词汇覆盖率、查询延迟。"""

import random
import sqlite3
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "validation/dict/words.db"
REF = ROOT / "artifacts/b2-final/reference.txt"

PROBES = ["resilient", "longevity", "prevalent", "blur", "eligible", "jargon",
          "acronym", "curriculum", "wurfing", "blurred", "trending"]


def main() -> None:
    conn = sqlite3.connect(DB)
    cur = conn.cursor()

    print("=== 抽样查询 ===")
    for word in PROBES:
        rows = cur.execute(
            "SELECT pos, definition, examples, synonyms FROM words WHERE lemma=? ORDER BY sense LIMIT 2",
            (word.lower(),)
        ).fetchall()
        if not rows:
            print(f"{word:12} —— 未收录")
            continue
        pos, definition, examples, synonyms = rows[0]
        print(f"{word:12} ({pos}) {definition[:110]}")
        if examples:
            print(f"{'':12} 例: {examples[:90]}")
        if len(rows) > 1:
            print(f"{'':12} 另有 {len(rows) - 1} 个义项")

    print("\n=== 课文词汇覆盖率 ===")
    import re
    text = REF.read_text(encoding="utf-8").lower()
    tokens = sorted(set(re.findall(r"[a-z][a-z'-]+", text)))
    found = 0
    missing = []
    for t in tokens:
        hit = cur.execute("SELECT 1 FROM words WHERE lemma=? LIMIT 1", (t,)).fetchone()
        if hit:
            found += 1
        else:
            missing.append(t)
    print(f"课文共 {len(tokens)} 个不同词形，词典命中 {found} 个（{found / len(tokens):.1%}）")
    print(f"未命中：{', '.join(missing[:25])}{' …' if len(missing) > 25 else ''}")

    print("\n=== 查询延迟 ===")
    sample = [r[0] for r in cur.execute("SELECT lemma FROM words ORDER BY RANDOM() LIMIT 2000")]
    t0 = time.time()
    for w in sample:
        cur.execute("SELECT definition FROM words WHERE lemma=? LIMIT 1", (w,)).fetchone()
    dt = (time.time() - t0) / len(sample) * 1000
    print(f"{len(sample)} 次查询平均 {dt:.3f} ms/次（含 Python 开销）")
    conn.close()


if __name__ == "__main__":
    main()
