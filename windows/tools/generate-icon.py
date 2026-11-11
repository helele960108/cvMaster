"""
从已确认的透明底圆润 CV 主图生成 Windows 图标，不再绘制旧剪贴板。
仅使用 Pillow；与 macOS 共用 native/Resources/AppIcon.png。
author: helele
since: 2026-10-19
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT.parent / "native" / "Resources" / "AppIcon.png"
ASSETS = ROOT / "src" / "CvMaster" / "Assets"
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def build_icon() -> Image.Image:
    with Image.open(SOURCE) as source:
        if source.size != (1024, 1024) or source.mode != "RGBA":
            raise ValueError("AppIcon.png must be a 1024px RGBA master")
        image = source.copy()
    if image.getchannel("A").getextrema() != (0, 255):
        raise ValueError("AppIcon.png must contain transparent and opaque pixels")
    return image


def main() -> None:
    icon = build_icon()
    ASSETS.mkdir(parents=True, exist_ok=True)
    icon.save(ASSETS / "app.png", format="PNG", optimize=True)
    icon.save(ASSETS / "app.ico", format="ICO", sizes=[(size, size) for size in SIZES])
    print(f"generated {ASSETS / 'app.ico'} and {ASSETS / 'app.png'}")


if __name__ == "__main__":
    main()
