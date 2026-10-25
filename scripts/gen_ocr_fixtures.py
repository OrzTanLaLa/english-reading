"""生成 OCR 版面测试图，用于回答「一块图里有多块文字时 OCR 怎么排」。

产物写到 app/entry/src/main/resources/rawfile/ 下，随 HAP 打包，真机探针页直接读。

图里每行都带显式编号（L1/R1…），这样 OCR 结果里的行序是否串栏一眼可见。

用法：python scripts/gen_ocr_fixtures.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "app" / "entry" / "src" / "main" / "resources" / "rawfile"

W, H = 1240, 1754  # A4 比例，接近手机/平板拍课本的分辨率

LEFT_LINES = [
    "L1  The last bell rang at four.",
    "L2  Most students had already",
    "L3  left the building, but Maria",
    "L4  stayed behind to finish her",
    "L5  essay about the river that",
    "L6  runs through her village.",
    "L7  Every summer she watched",
    "L8  the water carry branches.",
]
RIGHT_LINES = [
    "R1  The essay was not long, but",
    "R2  she rewrote the opening",
    "R3  paragraph four times, since",
    "R4  none of them sounded like",
    "R5  the river she remembered.",
    "R6  Her teacher once said that",
    "R7  descriptions should begin",
    "R8  with a sound, so she did.",
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("times.ttf", "georgia.ttf", "arial.ttf"):
        path = Path("C:/Windows/Fonts") / name
        if path.exists():
            return ImageFont.truetype(str(path), size)
    raise SystemExit("找不到可用字体（times.ttf/georgia.ttf/arial.ttf）")


def canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGB", (W, H), "white")
    return img, ImageDraw.Draw(img)


def draw_header(d: ImageDraw.ImageDraw, font: ImageFont.FreeTypeFont) -> None:
    d.text((90, 70), "H1  UNIT 3  READING: THE RIVER AND THE TOWN", font=font, fill="black")


def two_columns() -> None:
    """经典双栏课本排版：全宽标题 + 左右两栏正文。"""
    img, d = canvas()
    header_font = load_font(34)
    body_font = load_font(24)
    draw_header(d, header_font)

    top = 240
    step = 48
    for i, line in enumerate(LEFT_LINES):
        d.text((80, top + i * step), line, font=body_font, fill="black")
    for i, line in enumerate(RIGHT_LINES):
        d.text((660, top + i * step), line, font=body_font, fill="black")

    img.save(OUT / "two_col.png")


def two_blocks() -> None:
    """同页两块分离文字：标题块 + 正文块，中间留大片空白。"""
    img, d = canvas()
    title_font = load_font(46)
    body_font = load_font(24)

    d.text((80, 120), "H1  A Letter from the North", font=title_font, fill="black")
    d.text((80, 200), "H2  written in the winter of 1998", font=load_font(26), fill="black")

    top = 900
    for i, line in enumerate(LEFT_LINES[:6]):
        d.text((80, top + i * 48), line, font=body_font, fill="black")

    img.save(OUT / "two_blocks.png")


def single_column() -> None:
    """对照组：只有一块文字。"""
    img, d = canvas()
    body_font = load_font(24)
    top = 150
    for i, line in enumerate(LEFT_LINES + RIGHT_LINES):
        d.text((90, top + i * 44), line, font=body_font, fill="black")
    img.save(OUT / "single_col.png")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    two_columns()
    two_blocks()
    single_column()
    for name in ("two_col.png", "two_blocks.png", "single_col.png"):
        p = OUT / name
        print(f"{name}: {p.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
