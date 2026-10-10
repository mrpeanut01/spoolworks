#!/usr/bin/env python3
"""
Builds `brand-colours.json` — every maker's own name for every colour it sells — from the Open
Filament Database.

Why this exists
---------------
A colour's *name* is the maker's, not the colour's. Creality's `C12E1F` is "Red"; the nearest of
31,861 generic colour names is "Cherry Pie". Naming a spool therefore needs the maker's list for
that product line, and this is where it comes from.

What it keeps
-------------
Brand, product line, polymer, colour name and one hex. Everything else in the export — sizes,
stores, purchase links, print temperatures — is dropped: the export is 15 MB and this is the 1 MB
of it that names a colour.

These hexes are the makers' *published* colours. They are not measurements; the measured swatches
are `filament-swatches.json`, from filamentcolors.xyz, and `BrandColourCatalogue` reads both.

Usage:
    Tools/build-brand-colours.py [--all <path to all.json>] [--out <path>]

Without --all it downloads https://api.openfilamentdatabase.org/json/all.json.
"""
import argparse, collections, json, os, re, sys, urllib.request

SOURCE = "https://api.openfilamentdatabase.org/json/all.json"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "Sources", "SpoolworksCore", "Resources", "brand-colours.json")


def hex6(raw):
    """`#RRGGBB` / `#RRGGBBAA` / a list of them -> `RRGGBB`, or None."""
    if isinstance(raw, list):
        raw = raw[0] if raw else None
    if not isinstance(raw, str):
        return None
    digits = raw.strip().lstrip("#")[:6].upper()
    return digits if re.fullmatch(r"[0-9A-F]{6}", digits) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--all", help="a downloaded all.json")
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    if args.all:
        with open(args.all) as handle:
            data = json.load(handle)
    else:
        with urllib.request.urlopen(SOURCE, timeout=120) as response:
            data = json.load(response)

    brands = {b["id"]: b["name"].strip() for b in data["brands"]}
    filaments = {f["id"]: f for f in data["filaments"]}

    # brand -> (line, polymer) -> {colour name: hex}. A dict per line so a colour listed twice
    # (the same variant in two spool sizes shows up once per size upstream) is kept once.
    tree = collections.defaultdict(lambda: collections.defaultdict(dict))
    skipped = 0
    for variant in data["variants"]:
        filament = filaments.get(variant.get("filament_id"))
        colour = hex6(variant.get("color_hex"))
        name = (variant.get("name") or "").strip()
        if not filament or not colour or not name:
            skipped += 1
            continue
        line = (filament.get("name") or "").strip()
        polymer = (filament.get("material") or "").strip()
        tree[brands[filament["brand_id"]]][(line, polymer)].setdefault(name, colour)

    document = {
        "source": "https://openfilamentdatabase.org",
        "version": data.get("version"),
        "brands": [
            {
                "name": brand,
                "lines": [
                    {
                        "name": line,
                        "material": polymer,
                        # [name, hex] pairs: half the bytes of an object per colour.
                        "colours": [[n, h] for n, h in sorted(colours.items())],
                    }
                    for (line, polymer), colours in sorted(lines.items())
                ],
            }
            for brand, lines in sorted(tree.items(), key=lambda kv: kv[0].lower())
        ],
    }
    with open(args.out, "w") as handle:
        json.dump(document, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")

    count = sum(len(l["colours"]) for b in document["brands"] for l in b["lines"])
    print(f"{len(document['brands'])} brands, "
          f"{sum(len(b['lines']) for b in document['brands'])} lines, {count} colours "
          f"({skipped} skipped) -> {os.path.normpath(args.out)}", file=sys.stderr)


if __name__ == "__main__":
    main()
