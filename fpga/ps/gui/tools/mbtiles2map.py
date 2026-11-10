"""mbtiles2map.py - turns an MBTiles file (PNG tiles) into one ready-to-blit picture per zoom level for atak_gui.

    python mbtiles2map.py <area>.mbtiles <out dir> 14 15 16 17

For every zoom z it writes map_z<z>.bin:
    32-byte header (little-endian u32): 'ATKM', zoom, x0, y0, width, height, 0, 0
        x0, y0 = global Web-Mercator pixel of the top-left corner (tile column * 256, tile row * 256, XYZ rows)
    then width*height pixels, 4 bytes each, B G R X  (the byte order of the HDMI framebuffer)
Missing tiles are filled with a light grey. MBTiles stores rows bottom-up (TMS); they are flipped to XYZ here.
"""
import io
import sqlite3
import struct
import sys
from pathlib import Path

from PIL import Image

T = 256
GREY = (224, 224, 224)


def build(db, z, out):
    rows = db.execute("select tile_column, tile_row, tile_data from tiles where zoom_level=?", (z,)).fetchall()
    if not rows:
        print(f"z{z}: no tiles")
        return
    n = 1 << z
    tiles = {(c, n - 1 - r): d for c, r, d in rows}          # TMS row -> XYZ row
    xs = [c for c, _ in tiles]
    ys = [r for _, r in tiles]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = (x1 - x0 + 1) * T, (y1 - y0 + 1) * T
    img = Image.new("RGB", (w, h), GREY)
    for (c, r), d in tiles.items():
        img.paste(Image.open(io.BytesIO(d)).convert("RGB"), ((c - x0) * T, (r - y0) * T))
    r_, g_, b_ = img.split()
    bgrx = Image.merge("RGBA", (b_, g_, r_, Image.new("L", (w, h), 0))).tobytes()
    path = out / f"map_z{z}.bin"
    with open(path, "wb") as f:
        f.write(struct.pack("<4s7I", b"ATKM", z, x0 * T, y0 * T, w, h, 0, 0))
        f.write(bgrx)
    img.save(out / f"map_z{z}_preview.png")
    print(f"z{z}: {len(tiles)} tiles, {x1 - x0 + 1}x{y1 - y0 + 1} -> {w}x{h} px, {path.stat().st_size / 1e6:.1f} MB")


def main():
    src, out = sys.argv[1], Path(sys.argv[2])
    zooms = [int(z) for z in sys.argv[3:]] or [14, 15, 16, 17]
    out.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    for z in zooms:
        build(db, z, out)


if __name__ == "__main__":
    main()
