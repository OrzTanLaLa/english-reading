"""词形还原（WordNet morphy 的简化版），用于把 added/became/dictionaries 映射到原形。

这里只做规则还原 + 一张小规模不规则表；查库时按「原词 → 候选原形」顺序尝试。
"""

import re

IRREGULAR = {
    "was": "be", "were": "be", "been": "be", "am": "be", "is": "be", "are": "be",
    "went": "go", "gone": "go", "did": "do", "done": "do", "does": "do",
    "had": "have", "has": "have", "made": "make", "said": "say", "saw": "see",
    "seen": "see", "took": "take", "taken": "take", "came": "come", "got": "get",
    "gave": "give", "given": "give", "found": "find", "thought": "think",
    "became": "become", "began": "begin", "begun": "begin", "brought": "bring",
    "kept": "keep", "knew": "know", "known": "know", "left": "leave",
    "lost": "lose", "meant": "mean", "met": "meet", "paid": "pay", "ran": "run",
    "said": "say", "sold": "sell", "sent": "send", "spent": "spend", "stood": "stand",
    "taught": "teach", "told": "tell", "understood": "understand", "won": "win",
    "wrote": "write", "written": "write", "children": "child", "men": "man",
    "women": "woman", "people": "person", "feet": "foot", "teeth": "tooth",
    "mice": "mouse", "geese": "goose", "better": "good", "best": "good",
    "worse": "bad", "worst": "bad", "more": "much", "most": "much",
}

# 英语里不加 -s 的虚词/常用词，避免规则误伤（这些词本身在 WordNet 里也常缺）
KEEP_AS_IS = {"and", "or", "but", "if", "the", "a", "an", "of", "to", "in", "on",
              "at", "for", "with", "as", "by", "from", "that", "this", "it", "is"}


def candidates(word: str) -> list[str]:
    """按可能性从高到低给出候选原形（不含原词本身）。"""
    w = word.lower()
    if w in KEEP_AS_IS:
        return []
    out: list[str] = []

    def add(x: str) -> None:
        if x and x != w and len(x) >= 2 and x not in out:
            out.append(x)

    if w in IRREGULAR:
        add(IRREGULAR[w])

    if w.endswith("'s") or w.endswith("’s"):
        add(w[:-2])
    if w.endswith("s") and not w.endswith("ss"):
        add(w[:-1])
        if w.endswith("ies"):
            add(w[:-3] + "y")
        if w.endswith("es"):
            add(w[:-2])
            add(w[:-1])
    if w.endswith("ed"):
        add(w[:-2])
        add(w[:-1])
        if w.endswith("ied"):
            add(w[:-3] + "y")
        if len(w) > 4 and w[-3] == w[-4]:      # stopped -> stop
            add(w[:-3])
    if w.endswith("ing"):
        add(w[:-3])
        add(w[:-3] + "e")
        if len(w) > 5 and w[-4] == w[-5]:      # running -> run
            add(w[:-4])
    if w.endswith("ly"):
        add(w[:-2])
        if w.endswith("ily"):                  # happily -> happy
            add(w[:-3] + "y")
    if w.endswith("er"):
        add(w[:-2])
        add(w[:-1])
    if w.endswith("est"):
        add(w[:-3])
        add(w[:-2])
    return out


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()
