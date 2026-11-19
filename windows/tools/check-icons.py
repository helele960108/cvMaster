"""只读检查共享 CV 字标、状态图和可部署的平台资源。"""
from pathlib import Path
import struct
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "native/Resources"
ASSETS = ROOT / "windows/src/CvMaster/Assets"
ICO_SIZES = {(s, s) for s in (16, 20, 24, 32, 40, 48, 64, 128, 256)}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def png(path):
    with Image.open(path) as image:
        require(image.mode == "RGBA", f"{path}: expected RGBA")
        return image.copy()


def alpha(image):
    return image.getchannel("A")


def check_monochrome(image, rgb):
    # 解码与预乘 alpha 的舍入可能使半透明边缘相差几级灰阶；不允许有色边缘。
    pixels = getattr(image, "get_flattened_data", image.getdata)()
    colors = {pixel[:3] for pixel in pixels if pixel[3] == 255}
    require(colors <= {rgb} and any(pixel[3] >= 128 for pixel in pixels), "unexpected solid color or empty icon")
    require(all(r == g == b and abs(r - rgb[0]) <= 8 for r, g, b, a in pixels if a >= 128),
            "icon is not the expected monochrome")
    w, h = image.size
    require(all(image.getpixel((x, y))[3] == 0 for x in (0, w - 1) for y in (0, h - 1)),
            "icon corners must be transparent")


def check_states(active, inactive):
    require(active.size == inactive.size, "status canvases must match")
    require(ImageChops.subtract(active, inactive).getbbox() is None, "inactive state removed CV pixels")
    delta = ImageChops.subtract(inactive, active)
    require(delta.getextrema()[1] == 255, "pause marker missing")
    # 连续两列组均须可见，包含两竖条之间的透明间隙；用高覆盖率排除抗锯齿边缘。
    columns = [delta.crop((x, 0, x + 1, delta.height)).getextrema()[1] >= 128 for x in range(delta.width)]
    require(sum(bit and (x == 0 or not columns[x - 1]) for x, bit in enumerate(columns)) == 2,
            f"pause marker must have two distinct bars at {active.size}")


def ico(path, rgb):
    with Image.open(path) as image:
        require(image.ico.sizes() == ICO_SIZES, f"{path}: missing size")
        frames = {size: image.ico.getimage(size).convert("RGBA") for size in ICO_SIZES}
    for frame in frames.values():
        check_monochrome(frame, rgb)
    return frames


def check_icns():
    data = (RESOURCES / "AppIcon.icns").read_bytes()
    require(data[:4] == b"icns" and struct.unpack_from(">I", data, 4)[0] == len(data), "invalid ICNS")
    # iconutil 将 16/32px 普通图写成 ic04/ic05；Pillow 的 sizes 不枚举这两种块。
    chunks, offset = set(), 8
    while offset < len(data):
        tag, length = struct.unpack_from(">4sI", data, offset)
        require(length >= 8 and offset + length <= len(data), "invalid ICNS chunk")
        chunks.add(tag)
        offset += length
    require({b"ic04", b"ic05", b"ic07", b"ic08", b"ic09", b"ic10", b"ic11", b"ic12", b"ic13", b"ic14"}
            .issubset(chunks), "missing standard or Retina ICNS frame")
    with Image.open(RESOURCES / "AppIcon.icns") as image:
        check_monochrome(image.convert("RGBA"), (36, 36, 36))


def main():
    svg = ET.parse(RESOURCES / "AppIcon.svg").getroot()
    for name in ("app-mark", "status-mark", "pause-mark"):
        require(svg.find(f".//*[@id='{name}']") is not None, f"missing shared SVG geometry: {name}")
    master = png(RESOURCES / "AppIcon.png")
    require(master.size == (1024, 1024), "master must be 1024px")
    require(256 < master.getbbox()[3] - master.getbbox()[1] < 512, "app mark proportions changed")
    check_monochrome(master, (36, 36, 36))
    require(master.tobytes() == png(ASSETS / "app.png").tobytes(), "platform PNG masters differ")
    check_icns()
    ico(ASSETS / "app.ico", (36, 36, 36))

    normal = png(RESOURCES / "StatusIcon.png")
    paused = png(RESOURCES / "StatusIconPaused.png")
    check_monochrome(normal, (0, 0, 0))
    check_monochrome(paused, (0, 0, 0))
    check_states(alpha(normal), alpha(paused))
    require(paused.getbbox()[2] - paused.getbbox()[0] > paused.width * 0.9,
            "status icon should be tightly cropped")

    dark = ico(ASSETS / "tray-dark.ico", (36, 36, 36))
    white = ico(ASSETS / "tray-light.ico", (255, 255, 255))
    dark_paused = ico(ASSETS / "tray-dark-paused.ico", (36, 36, 36))
    white_paused = ico(ASSETS / "tray-light-paused.ico", (255, 255, 255))
    for size in ICO_SIZES:
        require(alpha(dark[size]).tobytes() == alpha(white[size]).tobytes() and
                alpha(dark_paused[size]).tobytes() == alpha(white_paused[size]).tobytes(),
                f"light and dark tray shapes differ at {size}")
        # 小尺寸边缘可能因重采样而有 ±1 灰阶差；半透明边缘不计入形状比较。
        active_mask = alpha(dark[size]).point(lambda value: 255 if value >= 128 else 0)
        paused_mask = alpha(dark_paused[size]).point(lambda value: 255 if value >= 128 else 0)
        check_states(active_mask, paused_mask)

    project = ET.parse(ASSETS.parent / "CvMaster.csproj").getroot()
    resources = ";".join(node.get("Include", "") for node in project.iter("Resource")).split(";")
    for color in ("dark", "light"):
        for suffix in ("", "-paused"):
            require(f"Assets\\tray-{color}{suffix}.ico" in resources, "tray resource not embedded")
    print("PASS: shared SVG, app assets, two unchanged-size states, and four nine-size tray icons")


if __name__ == "__main__":
    main()
