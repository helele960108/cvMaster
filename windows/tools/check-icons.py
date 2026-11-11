"""检查共享 CV 主图、平台派生图及打包引用；只读，不启动应用。"""
from pathlib import Path
import struct
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "native" / "Resources"
ASSETS = ROOT / "windows" / "src" / "CvMaster" / "Assets"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    with Image.open(RESOURCES / "AppIcon.png") as source:
        require(source.mode == "RGBA" and source.size == (1024, 1024), "master must be 1024px RGBA")
        master = source.copy()
    alpha = master.getchannel("A")
    require(alpha.getextrema() == (0, 255), "master must contain transparent and opaque pixels")
    require(master.getpixel((0, 0))[3] == 0, "no opaque app tile")
    require(master.getbbox() == (117, 305, 907, 719), "approved CV silhouette bounds changed")
    require(master.convert("RGB").getextrema() == ((36, 36),) * 3, "master must be solid monochrome")
    svg = ET.parse(RESOURCES / "AppIcon.svg").getroot()
    paths = svg.findall("{http://www.w3.org/2000/svg}path")
    require(len(paths) == 1 and paths[0].get("stroke-linecap") == "round", "retain one rounded vector path")
    with Image.open(RESOURCES / "StatusIcon.png") as status:
        require(status.size == (798, 422), "status icon must trim excessive blank space")
        expected = master.crop((113, 301, 911, 723))
        rgba = status.convert("RGBA")
        require(rgba.getchannel("A").tobytes() == expected.getchannel("A").tobytes(),
                "status alpha must exactly match the approved master crop")
        # sips 将完全透明像素的 RGB 清零；只比较实际可见的合成结果。
        background = Image.new("RGBA", expected.size, (255, 255, 255, 255))
        require(ImageChops.difference(Image.alpha_composite(background, rgba),
                                     Image.alpha_composite(background, expected)).getbbox(alpha_only=False) is None,
                "status glyph must visually match the approved master crop")
        require(status.getchannel("A").getbbox() == (4, 4, 794, 418), "status icon must retain transparent edge padding")
    with Image.open(ASSETS / "app.png") as windows:
        require(windows.convert("RGBA").tobytes() == master.tobytes(), "platform PNG masters differ")
    ico_data = (ASSETS / "app.ico").read_bytes()
    reserved, kind, count = struct.unpack_from("<HHH", ico_data)
    require((reserved, kind, count) == (0, 1, 9), "ICO must contain nine sizes")
    with Image.open(ASSETS / "app.ico") as ico:
        expected_sizes = {(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)}
        require(ico.ico.sizes() == expected_sizes, "missing ICO frame")
        for size in expected_sizes:
            frame = ico.ico.getimage(size).convert("RGBA")
            require(frame.getpixel((0, 0))[3] == 0, f"ICO {size} is opaque")
            require(frame.getchannel("A").getextrema()[1] > 0, f"ICO {size} is empty")
    icns_data = (RESOURCES / "AppIcon.icns").read_bytes()
    require(icns_data[:4] == b"icns", "invalid ICNS header")
    require(struct.unpack_from(">I", icns_data, 4)[0] == len(icns_data), "invalid ICNS length")
    # iconutil 将 16/32px 普通图写成 ic04/ic05；Pillow 的 sizes 不枚举这两种块。
    chunks = set()
    offset = 8
    while offset < len(icns_data):
        tag, length = struct.unpack_from(">4sI", icns_data, offset)
        require(length >= 8 and offset + length <= len(icns_data), "invalid ICNS chunk")
        chunks.add(tag)
        offset += length
    require({b"ic04", b"ic05", b"ic07", b"ic08", b"ic09", b"ic10", b"ic11", b"ic12", b"ic13", b"ic14"}
            .issubset(chunks), "missing standard or Retina ICNS frame")
    with Image.open(RESOURCES / "AppIcon.icns") as icns:
        require(icns.convert("RGBA").getpixel((0, 0))[3] == 0, "ICNS lost transparency")
    app_source = (ROOT / "native/CVMaster/CVMasterApp.swift").read_text()
    require('forResource: "StatusIcon"' in app_source and 'image.isTemplate = true' in app_source,
            "menu bar must load a theme-adaptive template")
    build = (ROOT / "native/scripts/build-app.sh").read_text()
    require('"$APP/Contents/Resources/StatusIcon.png"' in build, "status icon missing from bundle copy")
    print("PASS: approved monochrome master, vector, status crop, nine ICO frames, ICNS and bundle references")


if __name__ == "__main__":
    main()
