#!/usr/bin/env python3
"""
Builds `filament-barcodes.json` — the barcode printed on a filament box, and which maker, product
line and colour it is — from the Open Filament Database.

Why this exists
---------------
A box says exactly what is in it, in a form a camera reads without error: its GTIN (the EAN-13 or
UPC-A under the bars). Scanning that at Intake names the maker, the line and the colour in one go,
where a camera reading of the filament itself can only say what colour it looks like.

What it keeps
-------------
One row per barcode: the GTIN, the colour's name and published hex, and the spool's net weight,
grouped by maker and product line. A code the database files under two lines of one maker (it does,
for a few dozen) is kept under both; the app offers the first that the printer's catalogue lists.

Coverage is whatever the database holds — strong for FormFutura, Spectrum, Polymaker, SUNLU and
Bambu Lab, thin for Creality. A box that is not listed is remembered by the app the first time it
is scanned, so this file is a head start and not the whole answer.

Usage:
    Tools/build-filament-barcodes.py [--all <path to all.json>] [--out <path>]

Without --all it downloads https://api.openfilamentdatabase.org/json/all.json.
"""
import argparse, collections, json, os, re, sys, urllib.request

SOURCE = "https://api.openfilamentdatabase.org/json/all.json"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "Sources", "SpoolworksCore", "Resources",
                           "filament-barcodes.json")


def hex6(raw):
    """`#RRGGBB` / `#RRGGBBAA` / a list of them -> `RRGGBB`, or None."""
    if isinstance(raw, list):
        raw = raw[0] if raw else None
    if not isinstance(raw, str):
        return None
    digits = raw.strip().lstrip("#")[:6].upper()
    return digits if re.fullmatch(r"[0-9A-F]{6}", digits) else None


def gtin(raw):
    """A GTIN-8/12/13/14 with a correct check digit, as its digits; anything else -> None."""
    digits = re.sub(r"\D", "", str(raw or ""))
    if len(digits) not in (8, 12, 13, 14):
        return None
    body, check = digits[:-1], int(digits[-1])
    total = sum(int(d) * (3 if i % 2 == 0 else 1) for i, d in enumerate(reversed(body)))
    return digits if (10 - total % 10) % 10 == check else None


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
    variants = {v["id"]: v for v in data["variants"]}

    # brand -> (line, polymer) -> {gtin: [colour name, hex, grams]}
    tree = collections.defaultdict(lambda: collections.defaultdict(dict))
    skipped = 0
    for size in data["sizes"]:
        if not size.get("gtin"):
            continue
        code = gtin(size["gtin"])
        variant = variants.get(size.get("variant_id"))
        filament = filaments.get(variant.get("filament_id")) if variant else None
        colour = hex6(variant.get("color_hex")) if variant else None
        name = (variant.get("name") or "").strip() if variant else ""
        if not code or not filament or not colour or not name:
            skipped += 1
            continue
        line = (filament.get("name") or "").strip()
        polymer = (filament.get("material") or "").strip()
        grams = size.get("filament_weight")
        grams = int(grams) if isinstance(grams, (int, float)) and grams > 0 else 0
        tree[brands[filament["brand_id"]]][(line, polymer)].setdefault(code, [name, colour, grams])

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
                        # [gtin, colour name, hex, net grams (0 = not recorded)]
                        "codes": [[code] + row for code, row in sorted(codes.items())],
                    }
                    for (line, polymer), codes in sorted(lines.items())
                ],
            }
            for brand, lines in sorted(tree.items(), key=lambda kv: kv[0].lower())
        ],
    }
    with open(args.out, "w") as handle:
        json.dump(document, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")

    count = sum(len(l["codes"]) for b in document["brands"] for l in b["lines"])
    print(f"{len(document['brands'])} brands, "
          f"{sum(len(b['lines']) for b in document['brands'])} lines, {count} barcodes "
          f"({skipped} skipped) -> {os.path.normpath(args.out)}", file=sys.stderr)


if __name__ == "__main__":
    main()
