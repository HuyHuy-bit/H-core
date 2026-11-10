#!/usr/bin/env python3
"""Validate current backend receipts, matrices and retained evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.run_unit import digest, local_headers, simulation_result
from tools.unit_profiles import PROFILES

BACKEND_PROFILES = (
    'rename_bundle', 'rename_state', 'rename_checkpoints', 'rename_recovery',
    'reorder_buffer', 'rename_rob', 'serial_retirement', 'issue_queue', 'issue_backend',
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_hashes(root, hashes):
    require(bool(hashes), 'empty evidence inventory')
    for name, expected in hashes.items():
        path = root/name
        require(path.is_file() and digest(path) == expected, f'stale or missing evidence: {name}')


def stream_digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024*1024), b''):
        value.update(block)
    return value.hexdigest()


def check_archive(root, receipt):
    path = root/receipt['archive']
    require(path.is_file() and digest(path) == receipt['archive_sha256'], f'archive differs: {path}')
    with tarfile.open(path, 'r:gz') as bundle:
        manifest = json.load(bundle.extractfile('manifest.json'))
        require(manifest == {k: v for k, v in receipt.items() if k not in ('archive', 'archive_sha256')},
                'archive manifest differs')
        expected = {**receipt['inputs_sha256'], **receipt['artifacts_sha256']}
        members = bundle.getmembers()
        require(len(members) == len(expected)+1 and {m.name for m in members} == set(expected) | {'manifest.json'},
                'archive inventory differs')
        for name, value in expected.items():
            stream = bundle.extractfile(name)
            require(stream is not None and stream_digest(stream) == value,
                    f'archived evidence differs: {name}')


def check_unit(root, name, receipt):
    profile = PROFILES[name]
    config = json.loads((root/f'config/{name}.json').read_text())
    require(receipt['status'] == 'pass' and receipt['profile'] == config['profile'], f'{name}: no pass')
    fields = receipt['simulations']
    require(len(fields) == len(config['seeds']) and [f['seed'] for f in fields] == config['seeds'],
            f'{name}: incomplete seed matrix')
    for row in fields:
        output = profile['prefix']+' '.join(f'{key}={value}' for key, value in row.items())+'\n'
        simulation_result(output, profile, config, row['seed'])
    for key, expected in (
        ('mutations_detected', profile['mutations']),
        ('caller_assertions_checked', profile['negatives']),
        ('stimulus_guards_checked', profile['guards']),
    ):
        require(receipt[key] == list(expected), f'{name}: incomplete {key}')
    benches = list(root.glob(f'verif/*/{name}_tb.cpp'))
    require(len(benches) == 1, f'{name}: missing independent bench')
    bench = benches[0]
    paths = [*(root/p for p in config.get('sources', profile['sources'])), bench,
             *local_headers(root, bench), *(root/p for p in profile['inputs']),
             root/f'config/{name}.json', root/'tools/run_unit.py', root/'tools/unit_profiles.py',
             root/'Makefile', root/'config/toolchain.lock', root/'config/synthesis.lock']
    if 'lint_config' in config:
        paths.append(root/config['lint_config'])
    require(set(receipt['inputs_sha256']) == {str(p.relative_to(root)) for p in paths},
            f'{name}: incomplete input inventory')
    check_hashes(root, receipt['inputs_sha256'])
    check_hashes(root, receipt['artifacts_sha256'])
    check_archive(root, receipt)


def check_ownership(root, retained):
    config = json.loads((root/'config/rename_recovery_ownership.json').read_text())
    check_hashes(root, retained['inputs_sha256'])
    path = root/retained['archive']
    require(digest(path) == retained['archive_sha256'], 'ownership archive differs')
    with tarfile.open(path, 'r:gz') as bundle:
        raw = bundle.extractfile('manifest.json').read()
        require(hashlib.sha256(raw).hexdigest() == retained['manifest_sha256'], 'ownership manifest differs')
        manifest = json.loads(raw)
        require(manifest['status'] == retained['status'] == 'pass', 'ownership did not pass')
        require(manifest['inputs_sha256'] == retained['inputs_sha256'], 'ownership inputs differ')
        check_hashes(root, manifest['artifacts_sha256'])
        expected = {**manifest['inputs_sha256'], **manifest['artifacts_sha256']}
        for name, value in expected.items():
            require(stream_digest(bundle.extractfile(name)) == value,
                    f'ownership archived evidence differs: {name}')
    jobs = manifest['jobs']
    require([j['name'] for j in jobs] == ['covers', *[m['name'] for m in config['mutations']], 'baseline'],
            'ownership: incomplete job matrix')
    baseline, covers = jobs[-1], jobs[0]
    require(baseline['status'] == 'PASS' and baseline['mode'] == 'prove', 'ownership: proof missing')
    require(covers['status'] == 'PASS' and set(covers['covers_reached']) == set(config['required_covers']),
            'ownership: covers missing')
    for job, mutation in zip(jobs[1:-1], config['mutations']):
        require(job['status'] == 'FAIL' and job['expected_failure'] and not job['dut_assertions_enabled']
                and bool(job['traces']) and set(job['assertions_failed']) & set(mutation['assertions']),
                f'ownership: fault not independently detected: {mutation["name"]}')
    return len(config['required_covers']), len(config['mutations'])


def invalidate(root=ROOT):
    for name in ('out/backend_acceptance/receipt.json', 'evidence/receipts/backend_acceptance.json'):
        (root/name).unlink(missing_ok=True)


def main():
    invalidate()
    out = ROOT/'out/backend_acceptance'
    out.mkdir(parents=True, exist_ok=True)
    paths = [out/'receipt.json', ROOT/'evidence/receipts/backend_acceptance.json']
    receipts = {}
    for name in BACKEND_PROFILES:
        path = ROOT/f'evidence/receipts/{name}.json'
        check_unit(ROOT, name, json.loads(path.read_text()))
        receipts[str(path.relative_to(ROOT))] = digest(path)
    path = ROOT/'evidence/receipts/rename_recovery_ownership.json'
    covers, formal_faults = check_ownership(ROOT, json.loads(path.read_text()))
    receipts[str(path.relative_to(ROOT))] = digest(path)
    for name in ('receipt', 'mutation_receipt'):
        path = ROOT/f'out/prf/{name}.json'
        prf = json.loads(path.read_text())
        check_hashes(ROOT, prf['inputs_sha256'])
        check_hashes(ROOT, prf['artifacts_sha256'])
        require([row['seed'] for row in prf['simulation']] == [1, 42, 20260905]
                and all(row['cycles'] > 0 and row['reads'] > 0 for row in prf['simulation'])
                and prf['duplicate_write_rejected'], 'PRF: incomplete matrix')
        if name == 'mutation_receipt':
            require(prf['mutations_detected'] == ['bypass_lane1', 'reset_gate'], 'PRF: faults missing')
        receipts[str(path.relative_to(ROOT))] = digest(path)
    result = dict(schema=1, status='pass', profiles=list(BACKEND_PROFILES),
                  seeds=sum(len(json.loads((ROOT/f'config/{n}.json').read_text())['seeds']) for n in BACKEND_PROFILES),
                  mutations=sum(len(PROFILES[n]['mutations']) for n in BACKEND_PROFILES),
                  ownership_covers=covers, ownership_faults=formal_faults, prf_faults=2,
                  receipts_sha256=receipts,
                  inputs_sha256={p: digest(ROOT/p) for p in ('tools/check_backend.py', 'tools/unit_profiles.py', 'Makefile')},
                  full_core_accepted=False, isa_accepted=False)
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.with_suffix('.tmp').write_text(json.dumps(result, indent=2)+'\n')
        path.with_suffix('.tmp').replace(path)
    print(f'Backend acceptance: PASS; {len(BACKEND_PROFILES)} unit gates, {result["seeds"]} seeds, '
          f'{result["mutations"]} unit faults, {covers} ownership covers, {formal_faults} formal faults, 2 PRF faults')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--invalidate', action='store_true', help='Remove previous aggregate passes before a gate runs.')
    if parser.parse_args().invalidate:
        invalidate()
    else:
        main()
