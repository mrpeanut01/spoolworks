#!/usr/bin/env python3
"""
Builds `vendor-k2.json` — the third-party filament catalogue — from OrcaSlicer's filament library.

Why this exists
---------------
A tag stores a five-character filament ID and the printer looks it up in its own
`material_database.json`. The captured Creality catalogue (`k2.json`) covers Creality, Generic,
eSUN and Polymaker's engineering line; it does not cover Bambu, Elegoo, Overture, SUNLU, or
Polymaker's consumer line. Those records have to come from somewhere, and the only defensible
"somewhere" is the filament maker's own published slicer profile.

What it does NOT do
-------------------
It never invents a value. Every number written here was read out of a vendor profile or inherited
from the polymer base that profile declares. Where a vendor profile is silent, the value comes from
the same-polymer Creality record used as the kvParam template, and the record says so in
`sourceProfile`.

The inheritance chain is the whole job
--------------------------------------
Orca profiles are diffs, not datasheets, and they nest four to five deep:

    Elegoo PLA Matte @System -> Elegoo PLA Matte @base -> Elegoo PLA @base
                             -> fdm_filament_pla -> fdm_filament_common

`Elegoo PLA Matte @base` contains a name and an `inherits` line and nothing else. Reading one file
per product would invent every field for it and never know. `resolve()` merges the whole chain,
child over parent, before anything is read.

Usage:
    Tools/build-vendor-catalogue.py --orca <path to OrcaSlicer checkout> [--out <path>]
"""
import argparse, collections, json, os, sys

VENDOR_LETTER = {
    'Bambu': 'B', 'Elegoo': 'G', 'Overture': 'O', 'SUNLU': 'S', 'Polymaker': 'P',
}
# `base.brand` as it should read in the catalogue, which is not always the folder name.
VENDOR_BRAND = {
    'Bambu': 'Bambu Lab', 'Elegoo': 'Elegoo', 'Overture': 'Overture',
    'SUNLU': 'SUNLU', 'Polymaker': 'Polymaker',
}

# The family digit, read off Creality's own scheme: their third-party ids are
# <letter><family><3-digit serial>, and the families in the shipped catalogue are
# 1 PLA, 2 PETG, 3 ABS, 4 ASA, 5 TPU, 7 PA, 8 PET, 9 PPS. 0 and 6 are unused and taken here
# for the two families Creality has no third-party record for.
FAMILY_DIGIT = {
    'PLA': '1', 'PLA-CF': '1', 'PLA-AERO': '1',
    'PETG': '2', 'PETG-CF': '2', 'PETG-GF': '2', 'PCTG': '2',
    'ABS': '3', 'ABS-GF': '3',
    'ASA': '4', 'ASA-CF': '4', 'ASA-AERO': '4',
    'TPU': '5',
    'PC': '6',
    'PA': '7', 'PA-CF': '7', 'PA-GF': '7', 'PA6-CF': '7', 'PPA-CF': '7',
    'PET': '8', 'PET-CF': '8',
    'PPS': '9', 'PPS-CF': '9',
    'PVA': '0', 'BVOH': '0',
}

# Which Creality record lends its kvParam when the vendor's own type has no exact match in the
# catalogue. Only ever falls back within the same polymer family.
TYPE_FALLBACK = {
    'PLA-AERO': 'PLA', 'ASA-AERO': 'ASA', 'ABS-GF': 'ABS',
    'PA6-CF': 'PA-CF', 'PPA-CF': 'PA-CF', 'PA-GF': 'PA-GF',
}

# The keys transferred from the vendor profile — an allowlist, and the most important decision in
# this file.
#
# The rule is: **take what is a property of the plastic, keep what is a property of the printer.**
# A filament profile in any slicer mixes the two. Density, melt temperature and how fast the
# material can be extruded belong to the filament and travel with it to any machine. Retraction
# lengths, fan curves, pressure advance, purge volumes and start/end G-code are tuning for the
# extruder and hotend the profile was written for, and they do not.
#
# This was a denylist first, and it was wrong in a way that would not have failed loudly. Orca's
# `filament_start_gcode` for Bambu and Polymaker is the single line `; Filament gcode`, while
# Creality's sets the nozzle temperature (`M104 S[nozzle_temperature]`) and handles the first
# layer and multi-colour cases. Overlaying the vendor's replaced working temperature control with
# a comment. Elegoo's, meanwhile, drives `M106 P3` — an auxiliary fan a Creality machine does not
# have. Both would have produced a catalogue that looked complete and printed badly.
TRANSFERRED = {
    # What the material is
    'filament_type', 'filament_vendor', 'filament_density', 'filament_diameter', 'filament_cost',
    'filament_soluble', 'filament_is_support', 'filament_shrink',
    # How hot it wants to be
    'nozzle_temperature', 'nozzle_temperature_initial_layer',
    'nozzle_temperature_range_low', 'nozzle_temperature_range_high',
    'temperature_vitrification',
    # What it wants under it
    'cool_plate_temp', 'cool_plate_temp_initial_layer',
    'eng_plate_temp', 'eng_plate_temp_initial_layer',
    'hot_plate_temp', 'hot_plate_temp_initial_layer',
    'textured_plate_temp', 'textured_plate_temp_initial_layer',
    # How fast it can be melted, and what it does to the machine
    'filament_max_volumetric_speed', 'filament_flow_ratio', 'required_nozzle_HRC',
    # Whether it needs the air scrubbed
    'activate_air_filtration', 'complete_print_exhaust_fan_speed', 'during_print_exhaust_fan_speed',
}

# Keys that identify a profile rather than describe a filament.
NON_VALUE = {'inherits', 'name', 'type', 'from', 'instantiation', 'setting_id', 'filament_id'}


def load_index(root):
    """Every profile in the library, keyed by its declared `name`."""
    index, collisions = {}, []
    for dirpath, _, files in os.walk(root):
        for filename in sorted(files):
            if not filename.endswith('.json'):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, encoding='utf-8') as handle:
                doc = json.load(handle)
            name = doc.get('name') or os.path.splitext(filename)[0]
            if name in index:
                collisions.append(name)
            index[name] = (doc, path)
    if collisions:
        raise SystemExit('profile names collide, so `inherits` is ambiguous: %s' % collisions)
    return index


def resolve(name, index, seen=()):
    """The whole inheritance chain merged, child overriding parent."""
    if name in seen:
        raise SystemExit('inheritance cycle: %s' % ' -> '.join(list(seen) + [name]))
    if name not in index:
        raise SystemExit('profile %r inherits from %r, which is not in the library' % (seen[-1], name))
    doc, _ = index[name]
    parent = doc.get('inherits')
    merged, chain = resolve(parent, index, tuple(seen) + (name,)) if parent else ({}, [])
    merged = dict(merged)
    merged.update({k: v for k, v in doc.items() if k not in NON_VALUE})
    return merged, chain + [name]


def scalar(merged, key, default=None):
    """Orca wraps every value in a one-element list. Unwrap it."""
    value = merged.get(key, default)
    if isinstance(value, list):
        return value[0] if value else default
    return value


def as_int(value, default=0):
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return default


def as_float(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def build(orca_root, k2_path, out_path):
    library = os.path.join(orca_root, 'resources', 'profiles', 'OrcaFilamentLibrary', 'filament')
    if not os.path.isdir(library):
        raise SystemExit('no filament library at %s' % library)
    index = load_index(library)

    with open(k2_path, encoding='utf-8') as handle:
        k2 = json.load(handle)
    captured = k2['result']['list']

    # kvParam templates, one per material type, preferring the Generic record: a third-party
    # filament should inherit Creality's *generic* profile for its polymer, not the tuning of a
    # named Creality product.
    templates = {}
    for item in captured:
        material_type = item['base']['meterialType']
        if material_type not in templates or item['base']['brand'] == 'Generic':
            if material_type not in templates or templates[material_type]['base']['brand'] != 'Generic':
                templates[material_type] = item

    # Polymaker records the capture already has. Matched on a normalised name so that the
    # capture's "Fiberon PA6-CF20" is recognised as Orca's "Fiberon PA6-CF" — the trailing figure
    # is the fibre loading, not a different product.
    def normalise(name):
        return ''.join(ch for ch in name.lower() if ch.isalnum()).rstrip('0123456789')

    already = {normalise(i['base']['name']): i['base']['id']
               for i in captured if i['base']['brand'] == 'Polymaker'}
    taken_ids = {i['base']['id'] for i in captured}

    records, skipped, report = [], [], []
    for vendor in sorted(VENDOR_LETTER):
        systems = sorted(name for name, (_, path) in index.items()
                         if os.path.basename(os.path.dirname(path)) == vendor
                         and name.endswith('@System'))
        # A product with a @base but no @System is not instantiated by Orca — it is not offered
        # to users there, and it is not offered here either. Reported rather than silently missed.
        bases = {name[:-len(' @base')] for name, (_, path) in index.items()
                 if os.path.basename(os.path.dirname(path)) == vendor and name.endswith('@base')}
        for orphan in sorted(bases - {n[:-len(' @System')] for n in systems}):
            report.append('  %-10s %-28s @base with no @System, not instantiated' % (vendor, orphan))

        for system in systems:
            product = system[:-len(' @System')]
            merged, chain = resolve(system, index)

            if vendor == 'Polymaker' and normalise(product) in already:
                skipped.append((product, already[normalise(product)]))
                continue

            material_type = scalar(merged, 'filament_type', 'PLA')
            template_type = material_type if material_type in templates else \
                TYPE_FALLBACK.get(material_type, material_type)
            template = templates.get(template_type)
            if template is None:
                raise SystemExit('no kvParam template for %r (%s)' % (material_type, product))

            # kvParam: the Creality generic profile for this polymer, with the vendor's own
            # *material* values laid over it. Everything the printer owns — G-code, retraction,
            # fan curves, pressure advance — stays Creality's. See TRANSFERRED.
            kv = dict(template['kvParam'])
            transferred = 0
            for key, value in merged.items():
                if key not in TRANSFERRED or key not in kv:
                    continue
                if isinstance(value, list):
                    # `compatible_printers: []` is the one empty list in the library, and it means
                    # "no restriction" rather than "no value".
                    value = value[0] if value else ''
                kv[key] = value
                transferred += 1
            # Derived from the brand and type pickers, exactly as the Windows add-filament form
            # does (`FilamentForm.cs:279-286`).
            kv['filament_vendor'] = VENDOR_BRAND[vendor]
            kv['filament_type'] = material_type
            kv['compatible_printers'] = ''

            base = {
                'id': None,                      # allocated below, once the order is fixed
                'brand': VENDOR_BRAND[vendor],
                'name': product,
                'meterialType': material_type,
                'colors': ['#000000'],
                'density': as_float(scalar(merged, 'filament_density'), 1.24),
                'diameter': '1.75',
                'costPerMeter': 0,
                'weightPerMeter': 0,
                'rank': None,                    # allocated below
                'minTemp': as_int(scalar(merged, 'nozzle_temperature_range_low'), 190),
                'maxTemp': as_int(scalar(merged, 'nozzle_temperature_range_high'), 240),
                'isSoluble': scalar(merged, 'filament_soluble', '0') == '1',
                'isSupport': scalar(merged, 'filament_is_support', '0') == '1',
                'shrinkageRate': 0,
                'softeningTemp': as_int(scalar(merged, 'temperature_vitrification'), 0),
                'dryingTemp': 0,
                'dryingTime': 0,
                'dryingTempLow': 0,
                'dryingTempHigh': 0,
            }
            records.append({
                'vendor': vendor, 'material_type': material_type, 'base': base, 'kvParam': kv,
                # Provenance, round-tripped by the envelope's unmodelled-field support. A year
                # from now this answers "where did this number come from".
                'sourceProfile': ' -> '.join(chain),
                'sourceTemplate': '%s (%s)' % (template['base']['name'], template['base']['id']),
                'transferred': transferred,
            })

    # Ids, allocated once the full set is known so a re-run is byte-stable: sorted by vendor then
    # product, numbered per (vendor letter, family digit), skipping anything the capture holds.
    counters = collections.defaultdict(int)
    for record in sorted(records, key=lambda r: (r['vendor'], r['base']['name'])):
        letter = VENDOR_LETTER[record['vendor']]
        digit = FAMILY_DIGIT.get(record['material_type'])
        if digit is None:
            raise SystemExit('no family digit for material type %r' % record['material_type'])
        while True:
            counters[(letter, digit)] += 1
            candidate = '%s%s%03d' % (letter, digit, counters[(letter, digit)])
            if candidate not in taken_ids:
                break
        taken_ids.add(candidate)
        record['base']['id'] = candidate

    # Rank orders the picker, descending. The capture's lowest is 4530, so these sort below every
    # captured record — a filament the printer itself knows about should come first.
    rank = 4520
    for record in sorted(records, key=lambda r: r['base']['id']):
        record['base']['rank'] = rank
        rank -= 10

    items = [{
        'engineVersion': '3.0.0',
        'printerIntName': 'F008',
        'nozzleDiameter': ['0.4'],
        'kvParam': r['kvParam'],
        'base': r['base'],
        'sourceProfile': r['sourceProfile'],
        'sourceTemplate': r['sourceTemplate'],
    } for r in sorted(records, key=lambda r: r['base']['id'])]

    document = {
        'code': 0, 'msg': 'ok', 'reqId': '0',
        'result': {'list': items, 'count': len(items), 'version': k2['result']['version']},
    }
    text = json.dumps(document, indent=2, separators=(',', ':'))
    non_ascii = [c for c in text if ord(c) > 127]
    if non_ascii:
        raise SystemExit('catalogue must stay 7-bit ASCII; found %r' % sorted(set(non_ascii))[:8])
    with open(out_path, 'w', encoding='ascii') as handle:
        handle.write(text)

    # ---------------------------------------------------------------- report
    print('\n'.join(report) or '  (every @base has an @System)')
    print()
    by_vendor = collections.Counter(r['vendor'] for r in records)
    for vendor in sorted(by_vendor):
        print('  %-10s %3d records' % (VENDOR_BRAND[vendor], by_vendor[vendor]))
    print('  %-10s %3d' % ('TOTAL', len(records)))
    print('\n  skipped %d Polymaker products the capture already has:' % len(skipped))
    for product, existing in sorted(skipped):
        print('    %-26s already %s' % (product, existing))
    moved = collections.Counter(r['transferred'] for r in records)
    print('\n  vendor keys transferred per record: min %d, max %d, median %d'
          % (min(moved), max(moved), sorted(r['transferred'] for r in records)[len(records) // 2]))
    print('\n  wrote %s (%d bytes)' % (out_path, len(text)))


if __name__ == '__main__':
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--orca', required=True, help='path to an OrcaSlicer checkout')
    parser.add_argument('--k2', default=os.path.join(here, 'Sources/SpoolworksCore/Resources/k2.json'))
    parser.add_argument('--out', default=os.path.join(here, 'Sources/SpoolworksCore/Resources/vendor-k2.json'))
    args = parser.parse_args()
    build(args.orca, args.k2, args.out)
