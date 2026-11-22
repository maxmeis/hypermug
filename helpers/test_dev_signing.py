"""Tests the local signing setup's reuse and interrupted-setup paths."""

import os
import pathlib
import subprocess
import tempfile
import unittest


HELPER = pathlib.Path(__file__).with_name("dev-signing.sh")
HASH = "A" * 40


class DevSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = pathlib.Path(self.temp.name)
        self.keychain = root / "login.keychain-db"
        self.keychain.touch()
        self.state = root / "state"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        security = bin_dir / "security"
        security.write_text(
            """#!/bin/sh
case "$1" in
  login-keychain) printf '%s\\n' "$TEST_KEYCHAIN" ;;
  find-identity)
    if test -e "$TEST_STATE/valid"; then
      printf '  1) %s "HyperMug Local Development"\\n' "$TEST_HASH"
    fi ;;
  find-certificate)
    if test -e "$TEST_STATE/cert"; then
      printf '%s\\n' '-----BEGIN CERTIFICATE-----' 'fixture' '-----END CERTIFICATE-----'
    else
      exit 44
    fi ;;
  add-trusted-cert) touch "$TEST_STATE/valid" ;;
  import) echo 'unexpected import' >&2; exit 90 ;;
  *) echo "unexpected security command: $*" >&2; exit 91 ;;
esac
"""
        )
        security.chmod(0o755)
        openssl = bin_dir / "openssl"
        openssl.write_text("#!/bin/sh\necho 'unexpected certificate generation' >&2\nexit 92\n")
        openssl.chmod(0o755)
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(bin_dir) + os.pathsep + self.env["PATH"],
            TEST_KEYCHAIN=str(self.keychain),
            TEST_STATE=str(self.state),
            TEST_HASH=HASH,
        )
        self.state.mkdir()

    def run_helper(self, command):
        return subprocess.run(
            [str(HELPER), command],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_existing_identity_is_reused_without_generation(self):
        (self.state / "valid").touch()
        first = self.run_helper("setup")
        second = self.run_helper("setup")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.run_helper("identity").stdout.strip(), HASH)

    def test_interrupted_import_reuses_certificate(self):
        (self.state / "cert").touch()
        result = self.run_helper("setup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / "valid").exists())
        self.assertEqual(self.run_helper("identity").stdout.strip(), HASH)

    def test_missing_identity_requires_explicit_setup(self):
        result = self.run_helper("identity")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("make setup-dev", result.stderr)


if __name__ == "__main__":
    unittest.main()
