"""Paired core-prefix TAGE predictions, state, recovery and training."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ParallelTageTest(unittest.TestCase):
    def test_prefix_state_and_guard(self):
        with tempfile.TemporaryDirectory() as temp:
            sources = ['rtl/frontend/tage_predictor.sv', 'rtl/frontend/branch_predictor.sv',
                       'verif/frontend/tage_parallel_tb.sv']
            result = subprocess.run(['verilator', '--binary', '--timing', '--assert', '-Wall',
                                     '--x-initial', 'unique', '--top-module', 'tage_parallel_tb',
                                     '--Mdir', temp, *sources], cwd=ROOT, capture_output=True,
                                    text=True, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            binary = Path(temp)/'Vtage_parallel_tb'
            for seed in (1, 2, 3):
                result = subprocess.run([str(binary), '+verilator+rand+reset+2',
                                         f'+verilator+seed+{seed}'], cwd=ROOT, capture_output=True,
                                        text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('PASS parallel cycles=12000', result.stdout)
                print(result.stdout.splitlines()[0])
            result = subprocess.run([str(binary), '+bad_prefix'], cwd=ROOT, capture_output=True,
                                    text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('PREDICTOR_PARALLEL_PREFIX', result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
