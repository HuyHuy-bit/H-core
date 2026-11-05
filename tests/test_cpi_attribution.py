"""Check observer lifetimes and reject incomplete or inconsistent attribution."""
import copy
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from tools import run_cpi_attribution as attribution
from tools import run_coremark


class AttributionTests(unittest.TestCase):
    def row(self):
        return dict(counters={'all': dict(cycles=1, retire_1=1, head_read=0,
                                         early_memory_launch=0, forward_launch=0)},
                    attribution={'all': dict(cycles=1, retired=1, allocated=1,
                                             frontend_accepted=1, frontend_accepted_progress=1)},
                    per_pc={})

    def test_partitions_and_identity_conservation_reject_corruption(self):
        valid = self.row()
        attribution.check_attribution(valid)
        for key, value, signature in (
            ('cycles', 2, 'cycle window'),
            ('retired', 2, 'retirement window'),
            ('head_opportunity', 1, 'head partition'),
            ('head_opportunity_pending', 1, 'head survival partition'),
            ('frontend_hold', 1, 'frontend partition'),
            ('frontend_accepted_progress', 0, 'frontend progress partition'),
            ('live_at_end', 1, 'identity conservation'),
            ('redirect_dispatch_pending', 1, 'recovery partition'),
            ('retired_cfi', 1, 'branch issue accounting'),
            ('load_selected', 1, 'load partition'),
        ):
            broken = copy.deepcopy(valid)
            broken['attribution']['all'][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, signature):
                attribution.check_attribution(broken)
        broken = copy.deepcopy(valid)
        broken['attribution']['region'] = {}
        with self.assertRaisesRegex(ValueError, 'attribution scopes'):
            attribution.check_attribution(broken)

    def stream(self):
        schema = json.loads((attribution.ROOT/'config/commit_event.yaml').read_text())
        values = dict(valid=1, retired=1, instruction=0x13, pc_before=16, pc_after=20)
        packed = 0
        for field in schema['slot_fields']:
            packed = (packed << field['width']) | values.get(field['name'], 0)
        packed <<= schema['max_csr_effects'] * sum(f['width'] for f in schema['csr_fields'])
        words = ' '.join(f'{packed >> (32*i) & 0xffffffff:08x}' for i in range(33))
        return (f'EVENT 0 0 {words}\n'
                'COUNTER all cycles 1\nCOUNTER all retire_1 1\n'
                'PERF cycles=1 retired=1 zero=0 one=1 two=0 drain=0\nCORE PASS fixture\n')

    def measure(self, output):
        process = Mock(stdout=io.StringIO(output), returncode=0)
        with patch.object(attribution.subprocess, 'Popen', return_value=process):
            return attribution.measure(Path('simulator'), Path('image'), {'terminal': 16}, 1)

    def test_stream_recount_and_required_records(self):
        valid = self.stream()
        self.assertEqual(self.measure(valid)['perf']['retired'], 1)
        for broken, signature in (
            (valid.replace('retired=1 zero', 'retired=2 zero'), 'streamed edge recount'),
            (valid + 'COUNTER all cycles 1\n', 'duplicate measurement key'),
            (valid.replace('CORE PASS fixture\n', ''), 'simulation failed'),
            ('\n'.join(line for line in valid.splitlines() if not line.startswith('PERF'))+'\n', 'missing PERF'),
            (valid.replace('EVENT 0 0', 'EVENT 0 1'), 'event lane order'),
        ):
            with self.subTest(signature=signature), self.assertRaisesRegex(ValueError, signature):
                self.measure(broken)

    def test_output_or_trace_drift_is_rejected(self):
        row = dict(perf={}, counters={}, original_output_sha256='a', packed_sha256='b')
        for key in row:
            other = dict(row, **{key: 'changed'})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'instrumentation changed '+key):
                attribution.compare(row, other)

    def test_observer_dependencies_invalidate_measurement_reuse(self):
        paths = run_coremark.input_files('cached_core', {'sources': [], 'lint_config': 'lint.vlt'})
        for path in ('verif/core/perf_attribution.hpp', 'verif/core/perf_attribution_sample.hpp',
                     'verif/core/perf_attribution.vlt'):
            self.assertIn(path, paths)

    def test_observer_scenarios_and_intended_negative_signatures(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp)/'observer_test'
            subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-g',
                            '-I'+str(attribution.ROOT/'verif/core'),
                            str(attribution.ROOT/'verif/core/perf_attribution_test.cpp'),
                            '-o', str(binary)], check=True, capture_output=True, text=True, timeout=60)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn('ATTRIBUTION TEST PASS:', result.stdout)


if __name__ == '__main__':
    unittest.main()
