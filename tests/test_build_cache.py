"""Changed source with an old archive timestamp must invalidate cached objects."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildCacheTests(unittest.TestCase):
    def test_changed_old_source_rebuilds_and_unchanged_source_keeps_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, build = Path(tmp) / 'source', Path(tmp) / 'build'
            source.mkdir()
            build.mkdir()
            (source / 'input').write_text('new source')
            (source / 'unchanged').write_text('same')
            (build / 'input').write_text('old source')
            (build / 'unchanged').write_text('same')
            (build / 'output').write_text('old source')
            (build / 'Makefile').write_text('output: input\n\tcp input output\n')
            for name in ('input', 'unchanged'):
                os.utime(source / name, (100, 100))
                os.utime(build / name, (200, 200))
            os.utime(build / 'output', (300, 300))
            subprocess.run(['bash', str(ROOT / 'tools/release/sync_sources.sh'), str(source), str(build)], check=True)
            self.assertEqual((build / 'unchanged').stat().st_mtime, 200)
            self.assertEqual(subprocess.run(['make', '-q', 'output'], cwd=build).returncode, 1)
            subprocess.run(['make', 'output'], cwd=build, check=True, stdout=subprocess.DEVNULL)
            self.assertEqual((build / 'output').read_text(), 'new source')
            subprocess.run(['bash', str(ROOT / 'tools/release/sync_sources.sh'), str(source), str(build)], check=True)
            self.assertEqual(subprocess.run(['make', '-q', 'output'], cwd=build).returncode, 0)
