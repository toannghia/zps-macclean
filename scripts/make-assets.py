#!/usr/bin/env python3
"""Sinh Assets/AppIcon.icns và Assets/logo.png từ khois.png, logo-no.png."""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
SURFACE = (248, 250, 252, 255)  # #F8FAFC


def hexagon_cutout(path: Path, scale: int = 4) -> Image.Image:
    """Tách khối lục giác khỏi nền trắng, giữ nguyên chữ S trắng ở trong."""
    source = Image.open(path).convert("RGB")
    source = source.resize((source.width * scale, source.height * scale), Image.LANCZOS)

    # Tô từ góc ảnh nên chỉ phần trắng nối với viền bị bỏ, chữ S không bị đụng tới.
    flood = source.copy()
    marker = (255, 0, 255)
    for corner in [(0, 0), (flood.width - 1, 0), (0, flood.height - 1), (flood.width - 1, flood.height - 1)]:
        ImageDraw.floodfill(flood, corner, marker, thresh=40)
    background = ImageChops.difference(flood, Image.new("RGB", flood.size, marker)).convert("L")
    mask = background.point(lambda v: 255 if v > 8 else 0)
    # Khử răng cưa sau khi phóng to, rồi co mép vào một chút để bỏ quầng trắng.
    mask = mask.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.GaussianBlur(3))

    result = source.convert("RGBA")
    result.putalpha(mask)
    return result.crop(mask.point(lambda v: 255 if v > 128 else 0).getbbox())


def app_icon(hexagon: Image.Image) -> Image.Image:
    size = 1024
    # Nền bo góc 824px theo lưới icon macOS; để trống viền cho bóng hệ thống.
    canvas = Image.new("RGBA", (size * 2, size * 2), (0, 0, 0, 0))
    inset = 100 * 2
    ImageDraw.Draw(canvas).rounded_rectangle(
        (inset, inset, size * 2 - inset, size * 2 - inset), radius=370, fill=SURFACE)
    canvas = canvas.resize((size, size), Image.LANCZOS)

    height = 620
    width = round(hexagon.width * height / hexagon.height)
    mark = hexagon.resize((width, height), Image.LANCZOS)
    canvas.alpha_composite(mark, ((size - width) // 2, (size - height) // 2))
    return canvas


def write_icns(icon: Image.Image, target: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in [16, 32, 128, 256, 512]:
            for factor in [1, 2]:
                pixels = points * factor
                suffix = "@2x" if factor == 2 else ""
                icon.resize((pixels, pixels), Image.LANCZOS).save(iconset / f"icon_{points}x{points}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(target)], check=True)


def logo(path: Path, width: int = 960) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    image = image.crop(image.getchannel("A").point(lambda v: 255 if v > 16 else 0).getbbox())
    return image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)


def main() -> None:
    ASSETS.mkdir(exist_ok=True)
    icon = app_icon(hexagon_cutout(ROOT / "khois.png"))
    icon.save(ASSETS / "icon-preview.png")
    write_icns(icon, ASSETS / "AppIcon.icns")
    logo(ROOT / "logo-no.png").save(ASSETS / "logo.png")


if __name__ == "__main__":
    main()
