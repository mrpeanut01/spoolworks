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
import argparse, collections, json, os, re, sys

# Where each brand's profiles live, what to call it, and its id letter.
#
# Two layouts, because OrcaSlicer stores filament profiles two ways:
#
#   'library'  OrcaFilamentLibrary/filament/<Vendor>/ - one `@System` file per product, the clean
#              case. A filament maker contributing profiles for their own filament.
#   'printer'  <PrinterVendor>/filament/ - one file per product *per printer per nozzle*, because
#              the folder belongs to a printer maker who also sells filament. Anycubic ships 128
#              files for 28 products; Flashforge 421 for 46. Collapsing those is `pick_variants`.
SOURCES = [
    # (folder,       brand,          letter, layout)
    ('Bambu',        'Bambu Lab',    'B', 'library'),
    ('Elegoo',       'Elegoo',       'G', 'library'),
    ('Overture',     'Overture',     'O', 'library'),
    ('SUNLU',        'SUNLU',        'S', 'library'),
    ('Polymaker',    'Polymaker',    'P', 'library'),
    ('Anycubic',     'Anycubic',     'A', 'printer'),
    ('Flashforge',   'Flashforge',   'F', 'printer'),
    ('Prusa',        'Prusament',    'R', 'printer'),
]

# Product-name prefixes to ignore inside a printer vendor's folder: the generic profiles it ships
# for other people's filament, and the polymer bases. `Flashforge Generic PETG` is Flashforge's
# generic, not a Flashforge product.
def is_vendor_product(product, brand):
    if not product.startswith(brand):
        return False
    return not (product == brand or product.startswith(brand + ' Generic'))

# One upstream typo, folded rather than shipped as a second product: `Anycubic PLA Slik` is a
# single file, `Anycubic PLA Silk` is six, and they are the same filament.
PRODUCT_ALIASES = {'Anycubic PLA Slik': 'Anycubic PLA Silk'}

# The family digit, read off Creality's own scheme: their third-party ids are
# <letter><family><3-digit serial>, and the families in the shipped catalogue are
# 1 PLA, 2 PETG, 3 ABS, 4 ASA, 5 TPU, 7 PA, 8 PET, 9 PPS. 0 and 6 are unused and taken here
# for the two families Creality has no third-party record for.
FAMILY_DIGIT = {
    'PLA': '1', 'PLA-CF': '1', 'PLA-AERO': '1',
    'PETG': '2', 'PETG-CF': '2', 'PETG-GF': '2', 'PCTG': '2',
    'ABS': '3', 'ABS-GF': '3', 'ABS-CF': '3',
    'ASA': '4', 'ASA-CF': '4', 'ASA-AERO': '4', 'ASA-GF': '4',
    'TPU': '5', 'TPU-64D': '5', 'TPU-90A': '5', 'TPU-95A': '5', 'PEBA': '5',
    'PC': '6', 'PC-CF': '6', 'PC-GF': '6',
    'PA': '7', 'PA-CF': '7', 'PA-GF': '7', 'PA6-CF': '7', 'PA11-CF': '7', 'PA12-CF': '7',
    'PA66-CF': '7', 'PAHT-CF': '7', 'PPA-CF': '7', 'PPA-GF': '7',
    'PET': '8', 'PET-CF': '8',
    'PPS': '9', 'PPS-CF': '9',
    'PVA': '0', 'BVOH': '0', 'HIPS': '0', 'PVB': '0',
}

# Which Creality record lends its kvParam when the vendor's own type has no exact match in the
# catalogue. Only ever falls back within the same polymer family.
TYPE_FALLBACK = {
    'PLA-AERO': 'PLA', 'PVB': 'PLA',
    'ABS-GF': 'ABS', 'ABS-CF': 'ABS',
    'ASA-AERO': 'ASA', 'ASA-GF': 'ASA-CF',
    'PA6-CF': 'PA-CF', 'PA11-CF': 'PA-CF', 'PA12-CF': 'PA-CF', 'PA66-CF': 'PA-CF',
    'PAHT-CF': 'PA-CF', 'PPA-CF': 'PA-CF', 'PPA-GF': 'PA-GF',
    'PC-CF': 'PC', 'PC-GF': 'PC',
    'PEBA': 'TPU', 'TPU-64D': 'TPU', 'TPU-90A': 'TPU', 'TPU-95A': 'TPU',
    'HIPS': 'HIPS', 'PVA': 'PVA',
}

# The keys transferred from the vendor profile -- an allowlist, and the most important decision in
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
# a comment. Elegoo's, meanwhile, drives `M106 P3` -- an auxiliary fan a Creality machine does not
# have. Both would have produced a catalogue that looked complete and printed badly.
TRANSFERRED = {
    # What the material is
    'filament_type', 'filament_vendor', 'filament_density', 'filament_diameter',
    'filament_soluble', 'filament_is_support', 'filament_shrink',
    # How hot it wants to be
    'nozzle_temperature', 'nozzle_temperature_initial_layer',
    'nozzle_temperature_range_low', 'nozzle_temperature_range_high',
    'temperature_vitrification',
    # What it wants under it.
    #
    # `hot_plate_temp` only. Orca also carries `cool_plate_temp`, `eng_plate_temp` and
    # `textured_plate_temp` -- the Bambu ecosystem's interchangeable build plates, which a K2 does
    # not have. Their values disagreed across printer variants more than any other key, which is
    # what drew attention to them: they describe a plate, not a plastic, and the Creality generic
    # profile already holds the right figure for a Creality bed.
    'hot_plate_temp', 'hot_plate_temp_initial_layer',
    # How fast it can be melted, and what it does to the machine
    'filament_max_volumetric_speed', 'filament_flow_ratio', 'required_nozzle_HRC',
    # Whether it needs the air scrubbed. The flag is the material's business; the fan speeds that
    # follow from it are the printer's, and are left to the Creality profile.
    'activate_air_filtration',
}

# Structural facts, taken from the resolved chain whatever supplied them.
#
# These are classifications, not measurements. A profile that inherits `filament_type: PLA` from
# `fdm_filament_pla` has not failed to state its type - that *is* how the type is stated, and it is
# correct. Gating these on vendor provenance the way the measured values are gated stripped the
# type from 112 of ~200 products and left them unclassifiable.
STRUCTURAL = {'filament_type', 'filament_soluble', 'filament_is_support', 'filament_diameter'}

# Keys that identify a profile rather than describe a filament.
NON_VALUE = {'inherits', 'name', 'type', 'from', 'instantiation', 'setting_id', 'filament_id'}




def load_index(*roots):
    """Every profile under `roots`, keyed by its declared `name`; later roots win.

    Precedence matters and is not cosmetic. A printer vendor's folder carries its *own*
    `fdm_filament_pla` and friends, tuned for their machines, and their profiles inherit from
    those rather than from the shared library copies. Loading the shared bases first and the
    vendor's folder second is what makes `inherits: "fdm_filament_pla"` inside Anycubic's folder
    resolve to Anycubic's base, which is what Orca itself does.

    A collision *within* one root is still an error, because then nothing decides.
    """
    index = {}
    for root in roots:
        seen_here, collisions = {}, []
        for dirpath, _, files in os.walk(root):
            for filename in sorted(files):
                if not filename.endswith('.json'):
                    continue
                path = os.path.join(dirpath, filename)
                with open(path, encoding='utf-8') as handle:
                    doc = json.load(handle)
                name = doc.get('name') or os.path.splitext(filename)[0]
                if name in seen_here and seen_here[name] != path:
                    collisions.append(name)
                seen_here[name] = path
                index[name] = (doc, path)
        if collisions:
            raise SystemExit('profile names collide within %s: %s' % (root, collisions[:5]))
    return index


def resolve(name, index, seen=()):
    """The inheritance chain merged, child over parent, remembering *who supplied each key*.

    Provenance is the point. These profiles inherit from shared polymer bases
    (`fdm_filament_pla` and friends), and a base supplies a default for every key whether or not
    the filament maker ever stated one. Without knowing which file a value came from there is no
    way to tell "Bambu says 1.26 g/cm3" from "nobody said, so PLA's default of 1.24 showed up".

    That distinction decides the whole printer-vendor layout: `Anycubic ABS` resolves to a density
    of 1.05 on one Kobra and 1.24 on another, and 1.24 is not a second opinion about ABS — it is
    the *PLA* base default arriving because that variant never set one.

    - Returns: (values, sources, chain) where `sources[key]` is the profile name that last set it.
    """
    if name in seen:
        raise SystemExit('inheritance cycle: %s' % ' -> '.join(list(seen) + [name]))
    if name not in index:
        raise SystemExit('%r inherits from %r, which is not in the library' % (seen[-1] if seen else '?', name))
    doc, _ = index[name]
    parent = doc.get('inherits')
    if parent:
        values, sources, chain = resolve(parent, index, tuple(seen) + (name,))
        values, sources = dict(values), dict(sources)
    else:
        values, sources, chain = {}, {}, []
    for key, value in doc.items():
        if key in NON_VALUE:
            continue
        values[key] = value
        sources[key] = name
    return values, sources, chain + [name]


def is_default(profile_name):
    """True when a value came from a shared base rather than from the filament maker."""
    return profile_name.startswith('fdm_filament_') or profile_name.startswith('Generic ')


def scalar(value, default=None):
    """Orca wraps every value in a one-element list. `compatible_printers: []` means no restriction."""
    if isinstance(value, list):
        return value[0] if value else ''
    return default if value is None else value


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


def product_name(profile_name):
    """`Anycubic PLA Matte @Anycubic Kobra 3 0.4 nozzle` -> `Anycubic PLA Matte`.

    Split on `@` with optional leading space, because Flashforge has both
    `Flashforge HS PLA Burnt Ti @FF G4` and `Flashforge HS PLA Burnt Ti@FF G4 0.6 nozzle`.
    """
    return re.split(r'\s*@', profile_name)[0].strip()


def variant_rank(profile_name):
    """How much a variant's opinion is worth when several disagree.

    A 0.4 mm profile first: that is the nozzle every record here declares
    (`nozzleDiameter: ["0.4"]`), and volumetric speed and flow really do differ by nozzle. Then a
    variant with no nozzle in its name, which is the printer's default. Then everything else, so
    the choice is never arbitrary and never silently a 0.25.
    """
    lowered = profile_name.lower()
    if '0.4' in lowered:
        return 0
    if not re.search(r'0\.\d', lowered):
        return 1
    return 2


def collect(profiles, index, brand):
    """One product's material values, taken only where the filament maker actually stated them.

    `profiles` are every variant of a single product. For each transferable key this gathers the
    values that were *vendor-declared* (see `is_default`), prefers the 0.4 mm variant's, and
    reports any genuine disagreement between two vendor-declared figures — which is a real thing
    in this data and worth seeing rather than averaging away.

    A key no variant declares is simply absent, and the record then inherits Creality's value for
    that polymer. That is the honest outcome: we do not know what the maker thinks, so we do not
    put words in their mouth.
    """
    chosen, conflicts = {}, []
    for key in sorted(TRANSFERRED):
        structural = key in STRUCTURAL
        stated = []
        for profile in sorted(profiles, key=variant_rank):
            values, sources, _ = resolve(profile, index)
            if key not in values:
                continue
            if not structural and is_default(sources[key]):
                continue
            stated.append((profile, scalar(values[key])))
        if not stated:
            continue
        chosen[key] = stated[0][1]
        distinct = {v for _, v in stated}
        if len(distinct) > 1:
            conflicts.append((key, stated[0][0], stated[0][1], sorted(distinct)))
    return chosen, conflicts


def gather(orca_root):
    """Every product from every source, as (brand, letter, product, values, conflicts, chain)."""
    profiles_dir = os.path.join(orca_root, 'resources', 'profiles')
    library = os.path.join(profiles_dir, 'OrcaFilamentLibrary', 'filament')
    out, notes = [], []

    for folder, brand, letter, layout in SOURCES:
        root = os.path.join(library, folder) if layout == 'library' \
            else os.path.join(profiles_dir, folder, 'filament')
        if not os.path.isdir(root):
            raise SystemExit('no profiles at %s' % root)
        # A printer vendor's folder inherits from the shared polymer bases *and* from the
        # library's generic profiles - `Flashforge ABS Basic @FF C5` inherits `Generic ABS
        # @System` - so the whole library comes along underneath, with the vendor's own copies
        # layered on top.
        index = load_index(library, root) if layout == 'printer' else load_index(library)

        groups = collections.defaultdict(list)
        for name, (_, path) in index.items():
            if os.path.dirname(path) != root:
                continue
            product = PRODUCT_ALIASES.get(product_name(name), product_name(name))
            if layout == 'library':
                if not name.endswith('@System'):
                    continue
            elif not is_vendor_product(product, brand):
                continue
            groups[product].append(name)

        if layout == 'library':
            # Report a product that has a @base but was never instantiated - not offered in Orca,
            # so not offered here either.
            instantiated = {product_name(n) for n in index
                            if n.endswith('@System') and os.path.dirname(index[n][1]) == root}
            for name in sorted(index):
                if name.endswith('@base') and os.path.dirname(index[name][1]) == root \
                        and product_name(name) not in instantiated:
                    notes.append('  %-11s %-30s @base with no @System, not instantiated'
                                 % (brand, product_name(name)))

        for product, profiles in sorted(groups.items()):
            values, conflicts = collect(profiles, index, brand)
            _, _, chain = resolve(sorted(profiles, key=variant_rank)[0], index)
            out.append(dict(brand=brand, letter=letter, product=product, values=values,
                            conflicts=conflicts, chain=chain, variants=len(profiles)))
    return out, notes


def build(orca_root, k2_path, previous_path, out_path):
    with open(k2_path, encoding='utf-8') as handle:
        k2 = json.load(handle)
    captured = k2['result']['list']

    # kvParam templates, one per material type, preferring the Generic record: a third-party
    # filament should inherit Creality's *generic* profile for its polymer, not the tuning of a
    # named Creality product.
    templates = {}
    for item in captured:
        material_type = item['base']['meterialType']
        if material_type not in templates or (item['base']['brand'] == 'Generic'
                                              and templates[material_type]['base']['brand'] != 'Generic'):
            templates[material_type] = item

    def normalise(name):
        return ''.join(ch for ch in name.lower() if ch.isalnum()).rstrip('0123456789')

    already = {normalise(i['base']['name']): i['base']['id']
               for i in captured if i['base']['brand'] == 'Polymaker'}
    taken_ids = {i['base']['id'] for i in captured}

    # Ids already published keep their ids, whatever else changes. A tag written against B1002 is
    # a physical object in someone's hand; moving that id would orphan it. New products are
    # numbered around the pins.
    pinned = {}
    if previous_path and os.path.exists(previous_path):
        with open(previous_path, encoding='utf-8') as handle:
            for item in json.load(handle)['result']['list']:
                pinned[item['base']['name']] = item['base']['id']

    products, notes = gather(orca_root)
    records, skipped, dropped = [], [], []
    for entry in products:
        product, values = entry['product'], entry['values']

        if entry['brand'] == 'Polymaker' and normalise(product) in already:
            skipped.append((product, already[normalise(product)]))
            continue

        material_type = values.get('filament_type')
        if not material_type:
            # Without a declared type there is no family digit and no kvParam template, and
            # guessing one from the product name is how a PETG record ends up with PLA's profile.
            dropped.append((product, 'no filament_type declared'))
            continue
        template_type = material_type if material_type in templates else \
            TYPE_FALLBACK.get(material_type, material_type)
        template = templates.get(template_type)
        if template is None:
            dropped.append((product, 'no Creality template for %r' % material_type))
            continue

        kv = dict(template['kvParam'])
        for key, value in values.items():
            if key in kv:
                kv[key] = value
        kv['filament_vendor'] = entry['brand']
        kv['filament_type'] = material_type
        kv['compatible_printers'] = ''

        base = {
            'id': None,
            'brand': entry['brand'],
            'name': product,
            'meterialType': material_type,
            'colors': ['#000000'],
            'density': as_float(values.get('filament_density'),
                                as_float(template['base']['density'], 1.24)),
            'diameter': '1.75',
            'costPerMeter': 0,
            'weightPerMeter': 0,
            'rank': None,
            'minTemp': as_int(values.get('nozzle_temperature_range_low'), template['base']['minTemp']),
            'maxTemp': as_int(values.get('nozzle_temperature_range_high'), template['base']['maxTemp']),
            'isSoluble': values.get('filament_soluble', '0') == '1',
            'isSupport': values.get('filament_is_support', '0') == '1',
            'shrinkageRate': 0,
            # Creality's figure for this polymer where the maker is silent, not zero: zero is a
            # legitimate value in this field (most captured records carry it) so it cannot double
            # as "unknown", and the template is the same fallback density and temps already use.
            'softeningTemp': as_int(values.get('temperature_vitrification'),
                                    template['base'].get('softeningTemp', 0)),
            'dryingTemp': 0,
            'dryingTime': 0,
            'dryingTempLow': 0,
            'dryingTempHigh': 0,
        }
        records.append(dict(letter=entry['letter'], brand=entry['brand'], base=base, kvParam=kv,
                            material_type=material_type, conflicts=entry['conflicts'],
                            variants=entry['variants'], stated=len(values),
                            sourceProfile=' -> '.join(entry['chain']),
                            sourceTemplate='%s (%s)' % (template['base']['name'], template['base']['id'])))

    # Ids. Pinned first so a published id is reserved before anything new is numbered.
    counters = collections.defaultdict(int)
    for record in records:
        if record['base']['name'] in pinned:
            record['base']['id'] = pinned[record['base']['name']]
            taken_ids.add(record['base']['id'])
    for record in sorted(records, key=lambda r: (r['brand'], r['base']['name'])):
        if record['base']['id']:
            continue
        digit = FAMILY_DIGIT.get(record['material_type'])
        if digit is None:
            raise SystemExit('no family digit for material type %r (%s)'
                             % (record['material_type'], record['base']['name']))
        while True:
            counters[(record['letter'], digit)] += 1
            candidate = '%s%s%03d' % (record['letter'], digit, counters[(record['letter'], digit)])
            if candidate not in taken_ids:
                break
        taken_ids.add(candidate)
        record['base']['id'] = candidate

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
        **({'sourceConflicts': ['%s=%s of %s' % (k, taken, '/'.join(opts))
                                for k, _, taken, opts in r['conflicts']]} if r['conflicts'] else {}),
    } for r in sorted(records, key=lambda r: r['base']['id'])]

    document = {
        'code': 0, 'msg': 'ok', 'reqId': '0',
        'result': {'list': items, 'count': len(items), 'version': k2['result']['version']},
    }
    text = json.dumps(document, indent=2, separators=(',', ':'))
    non_ascii = sorted({c for c in text if ord(c) > 127})
    if non_ascii:
        raise SystemExit('catalogue must stay 7-bit ASCII; found %r' % non_ascii[:8])
    with open(out_path, 'w', encoding='ascii') as handle:
        handle.write(text)

    # ---------------------------------------------------------------- report
    if notes:
        print('\n'.join(notes) + '\n')
    by_brand = collections.Counter(r['brand'] for r in records)
    for _, brand, _, layout in SOURCES:
        if by_brand.get(brand):
            new = sum(1 for r in records if r['brand'] == brand and r['base']['name'] not in pinned)
            print('  %-11s %3d records  (%s layout, %d new)' % (brand, by_brand[brand], layout, new))
    print('  %-11s %3d' % ('TOTAL', len(records)))

    if skipped:
        print('\n  skipped %d Polymaker products the capture already has:' % len(skipped))
        for product, existing in sorted(skipped):
            print('    %-26s already %s' % (product, existing))
    if dropped:
        print('\n  dropped %d products:' % len(dropped))
        for product, why in sorted(dropped):
            print('    %-36s %s' % (product, why))

    moved = [r['stated'] for r in records]
    print('\n  vendor-declared keys per record: min %d, max %d, median %d'
          % (min(moved), max(moved), sorted(moved)[len(moved) // 2]))

    # Conflicts are split by what they cost. A disagreement about density or melt temperature
    # changes what comes out of the nozzle; one about a filtration flag does not. Both are written
    # onto the record as `sourceConflicts`, but only the first kind is worth reading here.
    LOUD = {'filament_density', 'nozzle_temperature', 'nozzle_temperature_initial_layer',
            'nozzle_temperature_range_low', 'nozzle_temperature_range_high', 'hot_plate_temp'}
    conflicted = [r for r in records if r['conflicts']]
    loud = [(r, [c for c in r['conflicts'] if c[0] in LOUD]) for r in conflicted]
    loud = [(r, c) for r, c in loud if c]
    print('\n  %d of %d records had printer variants that disagreed on a stated value;'
          % (len(conflicted), len(records)))
    print('  %d of those disagreed about something that changes a print. The 0.4 mm variant wins,'
          % len(loud))
    print('  and every record carries its own `sourceConflicts` so the choice stays inspectable.')
    for record, conflicts in loud[:14]:
        for key, _, taken, options in conflicts[:1]:
            print('    %-5s %-24s %-30s took %-7s of %s'
                  % (record['base']['id'], record['base']['name'][:24], key, taken, options))
    if len(loud) > 14:
        print('    ... and %d more' % (len(loud) - 14))

    if pinned:
        moved_ids = [r['base']['name'] for r in records
                     if r['base']['name'] in pinned and r['base']['id'] != pinned[r['base']['name']]]
        print('\n  %d published ids pinned; %d moved (must be 0)' % (len(pinned), len(moved_ids)))
        if moved_ids:
            raise SystemExit('published ids moved: %s' % moved_ids[:5])
    print('\n  wrote %s (%d bytes)' % (out_path, len(text)))


if __name__ == '__main__':
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--orca', required=True, help='path to an OrcaSlicer checkout')
    parser.add_argument('--k2', default=os.path.join(here, 'Sources/SpoolworksCore/Resources/k2.json'))
    parser.add_argument('--out', default=os.path.join(here, 'Sources/SpoolworksCore/Resources/vendor-k2.json'))
    parser.add_argument('--previous', default=os.path.join(here, 'Sources/SpoolworksCore/Resources/vendor-k2.json'),
                        help='a published catalogue whose ids must not move')
    args = parser.parse_args()
    build(args.orca, args.k2, args.previous, args.out)
