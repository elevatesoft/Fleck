import pathlib
import subprocess
import tempfile
import unittest
import product_wrapper as probe


BASE = pathlib.Path(__file__).resolve().parents[1]


class ProductSelectionTest(unittest.TestCase):
    def test_reviewed_transformation_and_fake_swift_fail_closed(self):
        original = (BASE / "Scripts/run-swift-tests-with-appkit-host.sh").read_bytes()
        wrapper = probe.transformed(original)
        self.assertRaises(ValueError, probe.transformed, original + b"\n")
        start = wrapper.index('if (( target_selected )); then\n  build_arguments=')
        end = wrapper.index('\nif [[ -n "${FLECK_TEST_SWIFT_BUILD_SYSTEM:-}"', start)
        selectors = wrapper[start:end]
        start = wrapper.index('  set +e\n  (\n    cd "$package_root"\n    swift "${build_arguments[@]}"')
        end = wrapper.index('\nfi\nif [[ "$bin_path"', start)
        command = wrapper[start:end]
        with tempfile.TemporaryDirectory() as td:
            fake = (
              'set -euo pipefail\ntarget_selected=1; test_target=FleckAgentProtocolTests\n'
              'package_root="$1"; log="$2"; swift_code="$3"\n'
              'swift(){ printf "%s\\n" "$*" >>"$log"; return "$swift_code"; }\n'
            )
            for status, expected_calls in ((0, [
                'build --product FleckAgentProtocolTests --disable-automatic-resolution',
                'build --show-bin-path --product FleckAgentProtocolTests --disable-automatic-resolution',
            ]), (23, [
                'build --product FleckAgentProtocolTests --disable-automatic-resolution',
            ])):
                log = pathlib.Path(td) / 'swift.log'
                if log.exists():
                    log.unlink()
                result = subprocess.run(['bash', '-c', fake + selectors + "\n" + command, 'test', td, str(log), str(status)])
                self.assertEqual(result.returncode, status)
                self.assertEqual(log.read_text().splitlines(), expected_calls)

    def test_reject_missing_duplicate_and_unrelated_bundle_artifacts(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            with self.assertRaisesRegex(ValueError, 'selected native test bundle'):
                probe.verify_output(root)
            expected = root / f'{probe.TARGET}.xctest'
            expected.mkdir()
            probe.verify_output(root)
            other = root / 'Unrelated.xctest'
            other.mkdir()
            with self.assertRaisesRegex(ValueError, 'selected native test bundle'):
                probe.verify_output(root)
            other.rmdir()
            (root / 'FleckApp.swiftmodule').mkdir()
            with self.assertRaisesRegex(ValueError, 'unrelated app'):
                probe.verify_output(root)
