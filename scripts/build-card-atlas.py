#!/usr/bin/env python3
"""Package the licensed SVGCards deck into one mobile-sized texture.

Requires Inkscape and Pillow. Input is a local SVGCards checkout at the commit
recorded in assets/cards/LICENSE.txt; no download occurs in the game or CI.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image

SOURCE_COMMIT = "f8df28774736ea2545fc8e7fb693eb55ce031945"
SUITS = ("spade", "heart", "diamond", "club")
RANKS = ("Ace", "2", "3", "4", "5", "6", "7", "8", "9", "10", "Jack", "Queen", "King")
FACE = (256, 384)
CELL = (272, 400)
PADDING = 8


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="SVGCards repository checkout")
    args = parser.parse_args()
    actual = subprocess.check_output(["git", "-C", str(args.source), "rev-parse", "HEAD"], text=True).strip()
    if actual != SOURCE_COMMIT:
        raise SystemExit("Use the exact SVGCards commit recorded in LICENSE.txt.")
    source = args.source / "Decks/Vertical2/svgs"
    destination = Path(__file__).resolve().parents[1] / "assets/cards"
    destination.mkdir(parents=True, exist_ok=True)
    files = [f"{suit}{rank}.svg" for suit in SUITS for rank in RANKS]
    files += ["blackJoker.svg", "redJoker.svg", "blueBack.svg"]
    atlas = Image.new("RGBA", (13 * CELL[0], 5 * CELL[1]))
    manifest = {"source_commit": SOURCE_COMMIT, "face": FACE, "cell": CELL, "padding": PADDING, "cards": []}
    with tempfile.TemporaryDirectory(prefix="rami-cards-") as temporary:
        temporary = Path(temporary)
        for index, name in enumerate(files):
            original = source / name
            svg = original.read_text()
            if name == "blueBack.svg":
                # A navy back suits the physical table. The original pattern
                # and all face/court illustrations remain intact.
                svg = svg.replace("#0000df", "#273e53").replace("#0000ff", "#273e53").replace("#00f", "#273e53")
            elif name not in ("blackJoker.svg", "redJoker.svg") and not any(name.endswith(rank + ".svg") for rank in ("Jack", "Queen", "King")):
                # The source's jumbo deck frames the number-card pips. Remove
                # that guide rectangle for the familiar unframed card layout.
                root = ET.fromstring(svg)
                for parent in root.iter():
                    for child in list(parent):
                        if child.tag.endswith("}rect") and "fill:none" in child.get("style", ""):
                            parent.remove(child)
                svg = ET.tostring(root, encoding="unicode")
            input_file = temporary / "card.svg"
            output_file = temporary / "card.png"
            input_file.write_text(svg)
            subprocess.run(["inkscape", str(input_file), "--export-type=png", f"--export-filename={output_file}",
                            f"--export-width={FACE[0]}", f"--export-height={FACE[1]}"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            with Image.open(output_file) as image:
                image = image.convert("RGBA")
                x, y = (index % 13) * CELL[0] + PADDING, (index // 13) * CELL[1] + PADDING
                atlas.paste(image, (x, y))
                # Extrude edge pixels into the gutters to avoid neighbours
                # bleeding into the indices in mipmaps and texture filtering.
                for column in range(PADDING):
                    atlas.paste(image.crop((0, 0, 1, FACE[1])), (x - column - 1, y))
                    atlas.paste(image.crop((FACE[0] - 1, 0, FACE[0], FACE[1])), (x + FACE[0] + column, y))
                strip = atlas.crop((x - PADDING, y, x + FACE[0] + PADDING, y + 1))
                last = atlas.crop((x - PADDING, y + FACE[1] - 1, x + FACE[0] + PADDING, y + FACE[1]))
                for row in range(PADDING):
                    atlas.paste(strip, (x - PADDING, y - row - 1))
                    atlas.paste(last, (x - PADDING, y + FACE[1] + row))
            manifest["cards"].append({"index": index, "source": name, "sha256": hashlib.sha256(original.read_bytes()).hexdigest()})
    atlas.save(destination / "classic-atlas.png", optimize=True)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Packaged {len(files)} classic illustrations into {atlas.width}×{atlas.height} pixels.")


if __name__ == "__main__":
    main()
