"""探测 MDX 结构：版本、加密标志、key block info 是否可解压。

MDX v2 布局：
  4 字节 header 长度（v2 需 XOR 0x3695）
  header（UTF-16LE XML）
  4 字节 adler32
  5×8 字节：key block 数 / 词条数 / key block info 解压后大小 / key block info 大小 / key block 总大小
  key block info（zlib）
  key blocks（zlib）
  4×8 字节：record block 数 / 词条数 / record block info 大小 / record block 总大小
  record block info（zlib）
  record blocks
"""

import re
import sys
import zlib
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

MDX = Path(__file__).resolve().parents[1] / "validation/dict/oaldpe.mdx"


def main() -> None:
    data = MDX.read_bytes()
    hlen = int.from_bytes(data[:4], "big") ^ 0x3695
    head = data[4:4 + hlen].decode("utf-16-le", errors="replace")
    end = head.find("</Dictionary>")
    print(f"header 长度字段={hlen}，</Dictionary> 位置={end}，字符数={len(head)}")

    for k in ("Encrypted", "RegisterBy", "Format", "GeneratedByEngineVersion"):
        m = re.search(k + r'="([^"]*)"', head)
        print(f"  {k} = {m.group(1) if m else '(缺)'}")

    off = 4 + hlen
    print(f"\nheader 后偏移 {off}，接下来 4 字节: {data[off:off+4].hex()}")
    off += 4

    labels = ["key_block_num", "entries", "kbi_decomp_size", "kbi_size", "key_block_size"]
    nums = []
    for label in labels:
        v = int.from_bytes(data[off:off + 8], "big")
        nums.append(v)
        print(f"  {label}: {v}")
        off += 8

    kbi_size = nums[3]
    blob = data[off:off + kbi_size]
    print(f"\nkey block info 前 16 字节: {blob[:16].hex()}")
    try:
        out = zlib.decompress(blob)
        print(f"zlib 解压成功：{len(out)} 字节（声明 {nums[2]}）")
    except Exception as e:  # noqa: BLE001
        print(f"zlib 解压失败：{type(e).__name__}: {e}")
        try:
            out = zlib.decompressobj().decompress(blob)
            print(f"  流式解压得到 {len(out)} 字节")
        except Exception as e2:  # noqa: BLE001
            print(f"  流式也失败：{e2}")


if __name__ == "__main__":
    main()
