"""Reject stale or incomplete benchmark evidence and ambiguous timing attribution."""
import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools import run_coremark as coremark
from tools import run_chip_timing_repaired as timing


class CoreMarkReceiptTests(unittest.TestCase):
    def manifest(self):
        return coremark.run_manifest(
            'cached_core', {'parameters': {'ICACHE': 1}}, {'rtl.sv': 'before'},
            {'verilator': 'version'}, b'image', 2, 1, {'warm': (16, 3, 32, 1), 'terminal': 48}, 1)

    def row(self, manifest):
        return dict(profile=manifest['profile'], latency=manifest['read_latency'],
                    inputs_sha256=coremark.manifest_digest(manifest), manifest=manifest,
                    validation={'status': 'pass'})

    def test_reuse_requires_identical_window_build_and_checker_inputs(self):
        manifest = self.manifest()
        row = self.row(manifest)
        previous = {'schema': 3, 'results': [row]}
        self.assertEqual(coremark.cached_result(previous, manifest), row)
        changes = {'warmup': 0, 'iterations': 3, 'region': [16, 1, 32, 1], 'terminal': 64,
                   'image_sha256': 'changed', 'parameters': {'ICACHE': 0},
                   'read_latency': 10, 'write_latency': 10, 'tools': {'verilator': 'new'},
                   'inputs_sha256': {'rtl.sv': 'after', 'checker.py': 'changed'}}
        for field, value in changes.items():
            with self.subTest(field=field):
                changed = copy.deepcopy(manifest)
                changed[field] = value
                self.assertIsNone(coremark.cached_result(previous, changed))

    def test_legacy_unvalidated_and_duplicate_rows_are_not_reused(self):
        manifest = self.manifest()
        row = self.row(manifest)
        self.assertIsNone(coremark.cached_result({'schema': 2, 'results': [row]}, manifest))
        self.assertIsNone(coremark.cached_result({'schema': 3, 'results': [row, row]}, manifest))
        row['validation']['status'] = 'partial'
        self.assertIsNone(coremark.cached_result({'schema': 3, 'results': [row]}, manifest))

    def test_successful_exit_without_terminal_marker_is_rejected(self):
        result = subprocess.CompletedProcess([], 0, 'PERF cycles=1 retired=1\n')
        with patch.object(coremark.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'CORE PASS'):
                coremark.run_rtl(Path('binary'), Path('image'), {'terminal': 48, 'warm': (16, 3, 32, 1)}, 1, [])

    def test_pass_requires_exact_unique_result_matrix(self):
        first = self.manifest()
        second = dict(first, read_latency=10, write_latency=10)
        rows = [self.row(first), self.row(second)]
        self.assertEqual(coremark.receipt_status(rows, [first, second], False), 'pass')
        for broken in (rows[:1], [rows[0], rows[0]], rows + rows[:1]):
            self.assertEqual(coremark.receipt_status(broken, [first, second], False), 'partial')
        self.assertEqual(coremark.receipt_status(rows, [first, second], True), 'census_only')

    def test_source_change_prevents_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'rtl.sv').write_text('before')
            with patch.object(coremark, 'ROOT', root):
                inputs = coremark.snapshot(['rtl.sv'])
                (root/'rtl.sv').write_text('after')
                with self.assertRaisesRegex(RuntimeError, 'input changed'):
                    coremark.publish(root/'receipt.json', {'status': 'pass'}, inputs)
                self.assertFalse((root/'receipt.json').exists())

    def test_manifest_includes_build_counter_reference_and_schema_dependencies(self):
        paths = coremark.input_files('cached_core', {'sources': ['rtl.sv'], 'lint_config': 'lint.vlt'})
        for path in ('tools/run_sail_differential.py', 'tools/run_cpi.py',
                     'verif/core/core_reference.hpp', 'verif/core/perf_counters.vlt',
                     'verif/core/reference.py', 'verif/lockstep/generated/commit_event.py',
                     'config/memory_protocol.yaml', 'config/cached_core.json'):
            self.assertIn(path, paths)

    def test_census_only_drops_prior_rtl_and_uses_isolated_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root/'isolated'
            output.mkdir()
            (root/'config').mkdir()
            (root/'config/cached_core.json').write_text(json.dumps({'sources': [], 'parameters': {},
                                                                  'lint_config': 'lint.vlt'}))
            (root/'lint.vlt').write_text('')
            old = {'schema': 3, 'status': 'pass', 'results': [self.row(self.manifest())]}
            (output/'receipt.json').write_text(json.dumps(old))
            original = root/'original.json'
            original.write_text(json.dumps(old))
            symbols = {'coremark_done': 48, 'core_bench_list': 16, 'stop_time': 32, 'coremark_log': 0}

            class Reference:
                memory = b'Correct operation validated\0'

                def __init__(self, image):
                    pass

                def step(self):
                    return {'pc_before': 48}

            def build(iterations):
                (output/'coremark.bin').write_bytes(b'image')
                return b'image', symbols

            with patch.multiple(coremark, ROOT=root, OUT=root/'unused', PROFILES=('cached_core',),
                                SHARED_INPUTS=(), Reference=Reference), \
                    patch.object(coremark, 'fetch'), patch.object(coremark, 'build', side_effect=build), \
                    patch.object(coremark, 'tool_versions', return_value={}), \
                    patch.object(coremark, 'build_fetched') as rtl, \
                    patch.object(sys, 'argv', ['run_coremark.py', '--census-only', '--out', str(output)]):
                coremark.main()
            receipt = json.loads((output/'receipt.json').read_text())
            self.assertEqual(receipt['status'], 'census_only')
            self.assertEqual(receipt['results'], [])
            self.assertIn('no RTL result', receipt['claim'])
            self.assertEqual(json.loads(original.read_text()), old)
            rtl.assert_not_called()


class TimingAttributionTests(unittest.TestCase):
    def test_tage_hierarchy_does_not_match_cache_stage_registers(self):
        self.assertEqual(timing.chain('core.frontend.prediction.predictor.tage_direction.direction.table_q'), 'E')
        self.assertEqual(timing.chain('core.backend.lsu.cached.dcache.stage_valid_q'), 'D')
        self.assertEqual(timing.chain('core.frontend.icache.cache.stage_valid_q'), 'C')
        self.assertEqual(timing.chain('core.backend.producer0.event_o'), 'A/B')

    def test_wire_library_is_refreshed_when_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory)/'source.lib', Path(directory)/'wire10x.lib'
            source.write_text('capacitance : 1.42e-05;\n'*4)
            target.write_text('stale')
            with patch.object(timing, 'LIB', source):
                timing.wire10x(target)
                self.assertEqual(target.read_text().count('capacitance : 1.42e-04;'), 4)
                source.write_text(source.read_text()+'changed\n')
                timing.wire10x(target)
                self.assertTrue(target.read_text().endswith('changed\n'))


if __name__ == '__main__':
    unittest.main()
