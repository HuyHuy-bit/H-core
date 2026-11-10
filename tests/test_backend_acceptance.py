"""Backend acceptance must reject incomplete or stale retained evidence."""
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from tools.check_backend import BACKEND_PROFILES, ROOT, check_archive, check_unit, invalidate
from tools.unit_profiles import PROFILES
from tools.run_unit import local_headers


class BackendAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        name = 'rename_bundle'
        self.name = name
        profile = PROFILES[name]
        config = json.loads((ROOT/f'config/{name}.json').read_text())
        paths = [*config.get('sources', profile['sources']), f'verif/backend/{name}_tb.cpp',
                 *profile['inputs'], 'tools/run_unit.py', 'tools/unit_profiles.py', 'Makefile',
                 'config/toolchain.lock', 'config/synthesis.lock']
        paths.extend(str(p.relative_to(ROOT)) for p in local_headers(ROOT, ROOT/f'verif/backend/{name}_tb.cpp'))
        for name in paths:
            path = self.root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, path)
        name = self.name
        (self.root/f'config/{name}.json').write_text(json.dumps(config))
        (self.root/'result.log').write_text('independent reference comparison passed\n')
        self.receipt = dict(
            status='pass', profile=config['profile'],
            simulations=[dict(seed=seed, cases=16264+config['random_cases_per_seed'],
                              **{key: 1 for key in profile['required']}) for seed in config['seeds']],
            mutations_detected=list(profile['mutations']), caller_assertions_checked=[], stimulus_guards_checked=[],
            inputs_sha256={p: self.hash(self.root/p) for p in [*paths, f'config/{name}.json']},
            artifacts_sha256={'result.log': self.hash(self.root/'result.log')},
        )
        data = dict(self.receipt)
        path = self.root/'evidence.tar.gz'
        with tarfile.open(path, 'w:gz') as bundle:
            contents = {name: (self.root/name).read_bytes()
                        for name in {**data['inputs_sha256'], **data['artifacts_sha256']}}
            contents['manifest.json'] = json.dumps(data).encode()
            for name, content in contents.items():
                info = tarfile.TarInfo(name)
                info.size = len(content)
                bundle.addfile(info, io.BytesIO(content))
        self.receipt.update(archive=path.name, archive_sha256=self.hash(path))

    @staticmethod
    def hash(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_complete_current_evidence_passes(self):
        check_unit(self.root, self.name, self.receipt)

    def test_missing_or_duplicate_seed_cannot_pass(self):
        for rows in (self.receipt['simulations'][:-1], [self.receipt['simulations'][0]]*3):
            broken = dict(self.receipt, simulations=rows)
            with self.subTest(rows=rows), self.assertRaisesRegex(RuntimeError, 'seed matrix'):
                check_unit(self.root, self.name, broken)

    def test_missing_mutation_or_fabricated_caller_check_cannot_pass(self):
        for key, value in (('mutations_detected', self.receipt['mutations_detected'][:-1]),
                           ('caller_assertions_checked', ['not_run']), ('stimulus_guards_checked', ['not_run'])):
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'incomplete'):
                check_unit(self.root, self.name, dict(self.receipt, **{key: value}))

    def test_failed_status_cannot_pass(self):
        with self.assertRaisesRegex(RuntimeError, 'no pass'):
            check_unit(self.root, self.name, dict(self.receipt, status='fail'))

    def test_changed_input_or_deleted_log_cannot_pass(self):
        for name in (f'config/{self.name}.json', 'result.log'):
            path = self.root/name
            original = path.read_bytes()
            path.write_bytes(original+b' ')
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, 'stale or missing'):
                check_unit(self.root, self.name, self.receipt)
            path.write_bytes(original)
        (self.root/'result.log').unlink()
        with self.assertRaisesRegex(RuntimeError, 'stale or missing'):
            check_unit(self.root, self.name, self.receipt)

    def test_removed_source_hash_cannot_hide_changed_rtl(self):
        broken = copy.deepcopy(self.receipt)
        del broken['inputs_sha256']['rtl/backend/rename_bundle.sv']
        with self.assertRaisesRegex(RuntimeError, 'input inventory'):
            check_unit(self.root, self.name, broken)

    def test_changed_archive_or_manifest_cannot_pass(self):
        path = self.root/self.receipt['archive']
        original = path.read_bytes()
        path.write_bytes(original+b'corruption')
        with self.assertRaisesRegex(RuntimeError, 'archive differs'):
            check_archive(self.root, self.receipt)
        path.write_bytes(original)
        broken = copy.deepcopy(self.receipt)
        broken['simulations'][0]['raw'] += 1
        with self.assertRaisesRegex(RuntimeError, 'manifest differs'):
            check_archive(self.root, broken)

    def test_backend_target_reaches_every_restored_gate(self):
        text = (ROOT/'Makefile').read_text()
        dependencies = next(line for line in text.splitlines() if line.startswith('backend-check:')).split()[1:]
        for name in BACKEND_PROFILES:
            self.assertIn(name.replace('_', '-')+'-check', dependencies)
        for target in ('rename-recovery-ownership-check', 'prf-check', 'prf-mutation-check'):
            self.assertIn(target, dependencies)
        self.assertIn('backend-check', next(line for line in text.splitlines() if line.startswith('check-all:')))
        self.assertIn('\t@python3 tools/check_backend.py\n', text)

    def test_plain_make_keeps_the_existing_doctor_default(self):
        command = subprocess.check_output(['make', '--no-print-directory', '-n', 'PROFILE=s0-host'], cwd=ROOT, text=True)
        self.assertEqual(command.splitlines(), ['python3 tools/doctor.py --lock config/toolchain.lock --profile "s0-host"'])

    def test_gate_start_removes_old_aggregate_passes(self):
        names = ('out/backend_acceptance/receipt.json', 'evidence/receipts/backend_acceptance.json')
        for name in names:
            path = self.root/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{"status":"pass"}')
        unit = self.root/'evidence/receipts/rename_bundle.json'
        unit.write_text('{"status":"pass"}')
        invalidate(self.root)
        self.assertTrue(unit.is_file())
        self.assertTrue(all(not (self.root/name).exists() for name in names))
        command = subprocess.check_output(['make', '--no-print-directory', '-n', 'backend-check'], cwd=ROOT, text=True)
        self.assertEqual(command.splitlines()[0], 'python3 tools/check_backend.py --invalidate')


if __name__ == '__main__':
    unittest.main()
