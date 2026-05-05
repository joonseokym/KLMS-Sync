#!/usr/bin/env python3

import sys
from pathlib import Path

from PIL import Image


def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit("Usage: build_pdf_from_images.py output.pdf image1.png [image2.png ...]")

    output_path = Path(sys.argv[1]).expanduser().resolve()
    image_paths = [Path(arg).expanduser().resolve() for arg in sys.argv[2:]]

    frames = []
    opened = []
    try:
        for image_path in image_paths:
            image = Image.open(image_path)
            opened.append(image)
            if image.mode != "RGB":
                image = image.convert("RGB")
            else:
                image = image.copy()
            frames.append(image)

        if not frames:
            raise SystemExit("No images provided")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        frames[0].save(
            output_path,
            "PDF",
            save_all=True,
            append_images=frames[1:],
            resolution=96.0,
        )
    finally:
        for image in opened:
            try:
                image.close()
            except Exception:
                pass
        for frame in frames:
            try:
                frame.close()
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
