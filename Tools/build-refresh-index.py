#!/usr/bin/env python3
"""
Builds `refresh-<family>.json` — how the app tells a catalogue record nobody has touched from one
that has been changed, so an update can bring the first up to date without clobbering the second.

For every record the app currently ships (the captured seed and the vendor catalogue), the index
holds its content fingerprint and the fingerprints of every earlier version of that record the
repository has ever committed. At load, a local record whose fingerprint is in `supersedes` is
exactly as an earlier version shipped it, and is replaced; a record whose fingerprint is nowhere
differs from everything we shipped, and is left alone.

History comes from git, so nothing is remembered by hand: every committed version of each catalogue
is read with `git show`. The existing index is carried forward too, so a record's history survives
even if the commits that produced it do not.

The fingerprint must match `FilamentFingerprint` in SpoolworksCore bit for bit. The canonical form is
documented there; `render` and `fingerprint` below mirror it, and a Swift test recomputes every
fingerprint in the index to prove the two still agree.

Usage:
    Tools/build-refresh-index.py [--family k2]
"""
import argparse, collections, hashlib, json, math, os, subprocess

UNIT, GROUP, RECORD = '\x1f', '\x1d', '\x1e'


def byte_order(keys):
    return sorted(keys, key=lambda key: key.encode('utf-8'))


def render(value):
    if value is None:
        return 'z'
    if isinstance(value, bool):                 # before int: in Python, True is an int
        return 'b:1' if value else 'b:0'
    if isinstance(value, int):
        return 'n:%d' % value
    if isinstance(value, float):
        if math.isfinite(value) and value == int(value) and abs(value) < 2 ** 53:
            return 'n:%d' % int(value)
        return 'n:' + repr(value)
    if isinstance(value, str):
        return 's:' + value
    if isinstance(value, list):
        return 'a:[' + GROUP.join(render(item) for item in value) + ']'
    if isinstance(value, dict):
        return 'o:{' + GROUP.join(k + UNIT + render(value[k]) for k in byte_order(value)) + '}'
    raise TypeError('cannot render %r' % (value,))


def fingerprint(item):
    base, kv = item['base'], item['kvParam']
    entries = ['base.' + key + UNIT + render(base[key]) for key in byte_order(base)]
    for key in byte_order(kv):
        if not isinstance(kv[key], str):
            raise SystemExit('kvParam %r on %s is not a string' % (key, base.get('id')))
        entries.append('kv.' + key + UNIT + 's:' + kv[key])
    return hashlib.sha256(RECORD.join(entries).encode('utf-8')).hexdigest()[:16]


def committed_versions(repo, relpath):
    """Every version of `relpath` git has, newest first, as (short hash, parsed document)."""
    try:
        revs = subprocess.check_output(['git', '-C', repo, 'log', '--format=%H', '--', relpath],
                                       stderr=subprocess.DEVNULL).decode().split()
    except subprocess.CalledProcessError:
        return []
    versions = []
    for rev in revs:
        try:
            raw = subprocess.check_output(['git', '-C', repo, 'show', '%s:%s' % (rev, relpath)],
                                          stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            continue                             # the file did not exist at that commit
        versions.append((rev[:7], json.loads(raw)))
    return versions


def build(repo, family, out_path):
    resources = 'Sources/SpoolworksCore/Resources'
    catalogues = ['%s/%s.json' % (resources, family), '%s/vendor-%s.json' % (resources, family)]
    records, report = {}, []

    for rel in catalogues:
        path = os.path.join(repo, rel)
        if not os.path.exists(path):
            continue
        with open(path, encoding='utf-8') as handle:
            current = {item['base']['id']: item for item in json.load(handle)['result']['list']}
        now = {pid: fingerprint(item) for pid, item in current.items()}
        older = collections.defaultdict(set)
        versions = committed_versions(repo, rel)
        for _, document in versions:
            for item in document['result']['list']:
                pid = item['base']['id']
                if pid in now:
                    previous = fingerprint(item)
                    if previous != now[pid]:
                        older[pid].add(previous)
        for pid, current_fp in now.items():
            if pid in records:
                raise SystemExit('id %s is in more than one catalogue; the index would be ambiguous' % pid)
            records[pid] = {'fingerprint': current_fp, 'supersedes': set(older[pid])}
        report.append((rel, len(now), [rev for rev, _ in versions],
                       sum(1 for pid in now if older[pid])))

    carried = 0
    if os.path.exists(out_path):
        with open(out_path, encoding='utf-8') as handle:
            previous_index = json.load(handle).get('records', {})
        for pid, entry in previous_index.items():
            if pid not in records:
                continue
            history = set(entry.get('supersedes', []))
            if entry.get('fingerprint') and entry['fingerprint'] != records[pid]['fingerprint']:
                history.add(entry['fingerprint'])
            before = len(records[pid]['supersedes'])
            records[pid]['supersedes'] |= history
            carried += len(records[pid]['supersedes']) - before

    document = {'family': family, 'records': {
        pid: {'fingerprint': entry['fingerprint'],
              'supersedes': sorted(entry['supersedes'] - {entry['fingerprint']})}
        for pid, entry in sorted(records.items())}}
    text = json.dumps(document, indent=2, separators=(',', ':'))
    with open(out_path, 'w', encoding='ascii') as handle:
        handle.write(text)

    for rel, count, revs, refreshable in report:
        print('  %-44s %3d records, %d committed versions (%s), %d with an earlier version'
              % (rel, count, len(revs), ' '.join(revs), refreshable))
    if carried:
        print('  carried %d fingerprints forward from the previous index' % carried)
    total = sum(1 for entry in document['records'].values() if entry['supersedes'])
    print('\n  %d of %d records can be refreshed from an earlier shipped version'
          % (total, len(document['records'])))
    print('  wrote %s (%d bytes)' % (out_path, len(text)))


if __name__ == '__main__':
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--family', default='k2')
    parser.add_argument('--out', default=None)
    args = parser.parse_args()
    out = args.out or os.path.join(repo, 'Sources/SpoolworksCore/Resources/refresh-%s.json' % args.family)
    build(repo, args.family, out)
