"""
生成 cvMaster Windows 应用图标：暖铜渐变圆角方块 + 白色剪贴板。
仅使用 Pillow，输出多尺寸 .ico 与 256px PNG。
author: helele
since: 2026-10-19
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "src" / "CvMaster" / "Assets"
ASSETS.mkdir(parents=True, exist_ok=True)
SIZE = 1024


def gradient(size: int) -> Image.Image:
    """自左上到右下的低饱和铜橙渐变。"""
    image = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(image)
    start = (195, 128, 80)
    end = (157, 82, 46)
    for y in range(size):
        ratio = y / max(1, size - 1)
        color = tuple(round(start[i] + (end[i] - start[i]) * ratio) for i in range(3))
        draw.line((0, y, size, y), fill=color + (255,))
    return image


def build_icon() -> Image.Image:
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((56, 56, SIZE - 56, SIZE - 56), radius=224, fill=255)
    image.paste(gradient(SIZE), (0, 0), mask)

    draw = ImageDraw.Draw(image)
    # 剪贴板主体与夹子，均使用略带暖调的白色。
    paper = (255, 249, 242, 255)
    copper = (169, 81, 44, 255)
    draw.rounded_rectangle((300, 268, 724, 800), radius=64, fill=paper)
    draw.rounded_rectangle((402, 196, 622, 322), radius=48, fill=paper)
    draw.rounded_rectangle((444, 230, 580, 292), radius=26, fill=copper)
    # 三行内容线，末端逐渐变短，形成轻盈的节奏。
    lines = [(384, 448, 640), (384, 560, 606), (384, 672, 520)]
    for left, top, right in lines:
        draw.rounded_rectangle((left, top, right, top + 28), radius=14, fill=copper)
    # 左上角高光，避免纯色平涂。
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.rounded_rectangle((56, 56, SIZE - 56, 300), radius=224, fill=(255, 255, 255, 20))
    image.alpha_composite(highlight)
    return image


def main() -> None:
    icon = build_icon()
    icon.save(ASSETS / "app.png", format="PNG", optimize=True)
    sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    icon.save(ASSETS / "app.ico", format="ICO", sizes=sizes)
    print(f"generated {ASSETS / 'app.ico'} and {ASSETS / 'app.png'}")


if __name__ == "__main__":
    main()
