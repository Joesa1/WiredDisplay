#!/usr/bin/env python3
"""Generate model-addressable transparent iMac product views without generative edits."""

from collections import deque
from hashlib import sha256
import json
from pathlib import Path
from statistics import median

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "Resources/DeviceAssets/Apple/iMac"
MANIFEST = ASSET_ROOT / "asset-manifest.json"
OUTPUT_ROOT = ASSET_ROOT / "transparent"
OUTPUT_INDEX = OUTPUT_ROOT / "manifest.json"
BACKGROUND_TOLERANCE = 26


def source_digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def has_transparency(image: Image.Image) -> bool:
    alpha = image.convert("RGBA").getchannel("A")
    return alpha.getextrema()[0] < 255


def corner_background(image: Image.Image) -> tuple[int, int, int]:
    width, height = image.size
    samples = []
    for x0, y0 in ((0, 0), (width - 8, 0), (0, height - 8), (width - 8, height - 8)):
        for x in range(max(x0, 0), min(x0 + 8, width)):
            for y in range(max(y0, 0), min(y0 + 8, height)):
                samples.append(image.getpixel((x, y))[:3])
    return tuple(int(median(channel)) for channel in zip(*samples))


def is_background(pixel: tuple[int, int, int, int], background: tuple[int, int, int]) -> bool:
    return all(abs(pixel[index] - background[index]) <= BACKGROUND_TOLERANCE for index in range(3))


def remove_connected_background(image: Image.Image) -> tuple[Image.Image, tuple[int, int, int], int]:
    rgba = image.convert("RGBA")
    width, height = rgba.size
    pixels = rgba.load()
    background = corner_background(rgba)
    seen = bytearray(width * height)
    queue = deque()

    def enqueue(x: int, y: int) -> None:
        offset = y * width + x
        if seen[offset] or not is_background(pixels[x, y], background):
            return
        seen[offset] = 1
        queue.append((x, y))

    for x in range(width):
        enqueue(x, 0)
        enqueue(x, height - 1)
    for y in range(height):
        enqueue(0, y)
        enqueue(width - 1, y)

    while queue:
        x, y = queue.popleft()
        for next_x, next_y in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= next_x < width and 0 <= next_y < height:
                enqueue(next_x, next_y)

    transparent = 0
    for y in range(height):
        for x in range(width):
            if seen[y * width + x]:
                red, green, blue, _ = pixels[x, y]
                pixels[x, y] = (red, green, blue, 0)
                transparent += 1
    return rgba, background, transparent


def main() -> None:
    data = json.loads(MANIFEST.read_text())
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    generated = []

    for view in data["preferredViews"]:
        source = ASSET_ROOT / view["file"]
        if not source.is_file():
            raise FileNotFoundError(source)
        original = Image.open(source)
        if has_transparency(original):
            output = original.convert("RGBA")
            method = "preserved-existing-alpha"
            background = None
            transparent_pixels = None
        else:
            output, background, transparent_pixels = remove_connected_background(original)
            method = "removed-corner-connected-background"

        for model in view["models"]:
            relative_output = Path("transparent") / f"{model.replace(',', '_')}.png"
            output.save(ASSET_ROOT / relative_output, "PNG")
            generated.append({
                "model": model,
                "sourceFile": view["file"],
                "sourceSHA256": source_digest(source),
                "outputFile": str(relative_output),
                "method": method,
                "backgroundRGB": background,
                "transparentPixelCount": transparent_pixels,
                "sourcePage": view["sourcePage"],
            })

    OUTPUT_INDEX.write_text(json.dumps({
        "schemaVersion": 1,
        "rule": "No generation, cropping, recoloring, sharpening, or product-pixel retouching. JPEG backgrounds are removed only when connected to an image edge and within the configured RGB tolerance.",
        "backgroundTolerance": BACKGROUND_TOLERANCE,
        "views": generated,
    }, indent=2) + "\n")
    print(f"Generated {len(generated)} transparent iMac views in {OUTPUT_ROOT}")


if __name__ == "__main__":
    main()
