"""Draws GyroSteer's icon (a steering wheel on a blue rounded square) into assets/.

    python3 packaging/make_icons.py     # needs Pillow; on a Mac also writes assets/GyroSteer.icns
"""
import math
import pathlib
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"


def draw(size: int) -> Image.Image:
    k = 4  # draw big, then scale down for smooth edges
    s = size * k
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # macOS-style margin and corner radius.
    m = s * 0.1
    d.rounded_rectangle([m, m, s - m, s - m], radius=s * 0.18, fill=(42, 120, 214, 255))
    c = s / 2
    w = s - 2 * m
    r = w * 0.33
    rim = w * 0.075
    ink = (255, 255, 255, 255)
    d.ellipse([c - r, c - r, c + r, c + r], outline=ink, width=int(rim))
    spoke = int(w * 0.07)
    turn = math.radians(-18)  # turned a little, so it reads as a wheel in motion

    def rot(dx, dy):
        return (c + dx * math.cos(turn) - dy * math.sin(turn), c + dx * math.sin(turn) + dy * math.cos(turn))

    inner = r - rim / 2
    for p in [rot(-inner, w * 0.03), rot(inner, w * 0.03), rot(0, inner)]:
        d.line([rot(0, 0), p], fill=ink, width=spoke)
    hub = w * 0.09
    d.ellipse([c - hub, c - hub, c + hub, c + hub], fill=ink)
    # The straight-ahead notch.
    top = [rot(0, -r - rim / 2), rot(0, -r + rim / 2)]
    d.line(top, fill=(42, 120, 214, 255), width=int(w * 0.035))
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    ASSETS.mkdir(exist_ok=True)
    draw(256).save(ASSETS / "icon-256.png")
    draw(512).save(ASSETS / "icon-512.png")
    if sys.platform == "darwin" and shutil.which("iconutil"):
        with tempfile.TemporaryDirectory() as tmp:
            iconset = pathlib.Path(tmp) / "GyroSteer.iconset"
            iconset.mkdir()
            for base in [16, 32, 128, 256, 512]:
                draw(base).save(iconset / f"icon_{base}x{base}.png")
                draw(base * 2).save(iconset / f"icon_{base}x{base}@2x.png")
            subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ASSETS / "GyroSteer.icns")], check=True)
    print("icons written to", ASSETS)


if __name__ == "__main__":
    main()
