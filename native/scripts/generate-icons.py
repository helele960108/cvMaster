"""从同一 SVG 生成两端的应用图标、菜单栏模板和托盘图标（macOS + Pillow）。"""
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "native" / "Resources"
ASSETS = ROOT / "windows" / "src" / "CvMaster" / "Assets"
SVG = "{http://www.w3.org/2000/svg}"
ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def rasterize(root, elements, work, name):
    svg, png = work / f"{name}.svg", work / f"{name}.png"
    document = ET.Element(root.tag, root.attrib)
    for element in elements:
        document.append(deepcopy(element))
    ET.ElementTree(document).write(svg, encoding="utf-8")
    # sips 的 SVG 解码器需要根元素使用默认命名空间。
    subprocess.run(["sips", "-s", "format", "png", str(svg), "--out", str(png)],
                   check=True, stdout=subprocess.DEVNULL)
    with Image.open(png) as image:
        return image.convert("RGBA")


def colorize(mask, rgb):
    image = Image.new("RGBA", mask.size, (*rgb, 0))
    image.putalpha(mask)
    return image


def status_masks(root, work):
    mark = root.find(f".//*[@id='status-mark']")
    pause = root.find(f".//*[@id='pause-mark']")
    active = rasterize(root, [mark], work, "active").getchannel("A")
    inactive = rasterize(root, [mark, pause], work, "inactive").getchannel("A")
    left, top, right, bottom = inactive.getbbox()
    # 两种状态使用同一边界，切换时 CV 不移位、不缩放。
    padding = 8
    bounds = (left - padding, top - padding, right + padding, bottom + padding)
    return active.crop(bounds), inactive.crop(bounds)


def save_ico(mask, rgb, path):
    # 只重采样 alpha，再填充纯色，避免小尺寸边缘产生色差。
    frames = [colorize(mask.resize((s, s), Image.Resampling.LANCZOS), rgb) for s in ICO_SIZES]
    frames[-1].save(path, sizes=[frame.size for frame in frames], append_images=frames[:-1])


def main():
    ET.register_namespace("", SVG[1:-1])
    root = ET.parse(RESOURCES / "AppIcon.svg").getroot()
    with TemporaryDirectory(prefix="cvmaster-icons-") as temporary:
        work = Path(temporary)
        master = rasterize(root, [root.find(f"{SVG}path[@id='app-mark']")], work, "master")
        for output in (RESOURCES / "AppIcon.png", ASSETS / "app.png"):
            master.save(output, optimize=True)
        app_path = root.find(f"{SVG}path[@id='app-mark']")
        stroke = app_path.attrib["stroke"].removeprefix("#")
        rgb = tuple(bytes.fromhex(stroke))
        save_ico(master.getchannel("A"), rgb, ASSETS / "app.ico")

        iconset = work / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for suffix, scale in (("", 1), ("@2x", 2)):
                master.resize((size * scale,) * 2, Image.Resampling.LANCZOS).save(
                    iconset / f"icon_{size}x{size}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(RESOURCES / "AppIcon.icns")],
                       check=True)

        for mask, name, ico_suffix in zip(status_masks(root, work), ("StatusIcon", "StatusIconPaused"), ("", "-paused")):
            colorize(mask, (0, 0, 0)).save(RESOURCES / f"{name}.png", optimize=True)
            # 托盘提供正方形 ICO；保留透明安全边界，主体比应用图标更大。
            width = 960
            height = round(width * mask.height / mask.width)
            square = Image.new("L", (1024, 1024))
            square.paste(mask.resize((width, height), Image.Resampling.LANCZOS),
                         ((1024 - width) // 2, (1024 - height) // 2))
            for color, rgb in (("dark", (36, 36, 36)), ("light", (255, 255, 255))):
                save_ico(square, rgb, ASSETS / f"tray-{color}{ico_suffix}.ico")
    print("已从 AppIcon.svg 生成 macOS 与 Windows 图标")


if __name__ == "__main__":
    main()
