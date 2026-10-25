"""把 OEWN（Open English WordNet）的 JSON 提取成 App 用的 SQLite。

数据来源：english-wordnet-2025-json.zip（CC BY 4.0，需署名 Princeton WordNet + OEWN）
  entries-*.json ：按词条组织，键是 lemma，值里按词性给出 sense → synset id
  noun.*/verb.*/adj.*/adv.*.json ：synset 表，含英文释义、例句、同义词、词性

输出：words.db
  words(lemma, pos, sense, definition, examples, synonyms)
  meta(key, value)

用法：python scripts/build_dict.py [--src validation/dict/oewn] [--out validation/dict/words.db]
"""

import argparse
import json
import sqlite3
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]

POS_NAMES = {"n": "noun", "v": "verb", "a": "adjective", "s": "adjective", "r": "adverb"}


def example_text(item) -> str:
    """OEWN 的 example 有时是字符串，有时是 {"text": ...} 之类的对象。"""
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        return item.get("text") or item.get("example") or item.get("value") or ""
    return str(item)


def load_synsets(src: Path) -> dict:
    synsets = {}
    for f in sorted(src.glob("*.json")):
        name = f.name
        if not name.startswith(("noun.", "verb.", "adj.", "adv.")):
            continue
        with f.open(encoding="utf-8") as fh:
            data = json.load(fh)
        for sid, s in data.items():
            synsets[sid] = {
                "definition": " ".join(s.get("definition", [])),
                "examples": [example_text(e) for e in s.get("example", []) if example_text(e)],
                "members": s.get("members", []),
                "pos": POS_NAMES.get(s.get("partOfSpeech", ""), s.get("partOfSpeech", "")),
            }
    return synsets


def build(src: Path, out: Path) -> None:
    t0 = time.time()
    print("读取 synset...")
    synsets = load_synsets(src)
    print(f"  {len(synsets):,} 个 synset，用时 {time.time() - t0:.1f}s")

    if out.exists():
        out.unlink()
    conn = sqlite3.connect(out)
    cur = conn.cursor()
    cur.executescript("""
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE words(
            lemma TEXT NOT NULL,
            pos TEXT,
            sense INTEGER,
            definition TEXT,
            examples TEXT,
            synonyms TEXT
        );
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    """)

    rows = []
    entries = 0
    missing = 0
    for f in sorted(src.glob("entries-*.json")):
        with f.open(encoding="utf-8") as fh:
            data = json.load(fh)
        for lemma, poses in data.items():
            entries += 1
            for pos_key, body in poses.items():
                if not isinstance(body, dict):
                    continue
                senses = body.get("sense", [])
                for idx, sense in enumerate(senses):
                    syn = synsets.get(sense.get("synset"))
                    if syn is None:
                        missing += 1
                        continue
                    synonyms = [m for m in syn["members"] if m.lower() != lemma.lower()]
                    rows.append((
                        lemma.lower(),
                        POS_NAMES.get(pos_key, pos_key),
                        idx,
                        syn["definition"],
                        " | ".join(syn["examples"][:3]),
                        ", ".join(synonyms[:8]),
                    ))

    cur.executemany("INSERT INTO words VALUES (?,?,?,?,?,?)", rows)
    cur.execute("CREATE INDEX idx_words_lemma ON words(lemma)")
    cur.executemany("INSERT INTO meta VALUES (?,?)", [
        ("source", "Open English WordNet 2025"),
        ("license", "CC BY 4.0 (attribution: Princeton WordNet + Open English WordNet)"),
        ("entries", str(entries)),
        ("rows", str(len(rows))),
    ])
    conn.commit()
    cur.execute("VACUUM")
    conn.close()

    size_mb = out.stat().st_size / 1024 / 1024
    print(f"完成：{len(rows):,} 行、{entries:,} 个词条，{size_mb:.1f} MB，"
          f"未匹配 synset {missing}，总用时 {time.time() - t0:.1f}s")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(ROOT / "validation/dict/oewn"))
    ap.add_argument("--out", default=str(ROOT / "validation/dict/words.db"))
    args = ap.parse_args()
    build(Path(args.src), Path(args.out))


if __name__ == "__main__":
    main()
