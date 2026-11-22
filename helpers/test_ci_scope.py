"""CI selection tests use real Git histories, including renames and divergent PRs."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ci_scope import content_only, native_required

WORKFLOW = Path(__file__).resolve().parents[1] / ".woodpecker/ci-macos.yaml"


class ScopeTests(unittest.TestCase):
    def test_only_known_non_native_paths_are_lightweight(self):
        self.assertTrue(content_only([
            "README.md", "CONTRIBUTING.md", "Casks/README.md", "docs/configuration.md",
            "Source/Website/style.css", "Source/Skills/my-mac-wrench/SKILL.md",
            "Casks/hypermug.rb",
        ]))
        for path in ["Makefile", "package-lock.json", ".github/workflows/ci.yml",
                     "helpers/ci_scope.py", "helpers/test_release_metadata.py",
                     "Source/HyperMug/Info.plist", "Source/Branding/HyperMug.icns",
                     "unknown.md", "Casks/other.rb", "docs/../Makefile",
                     "/docs/guide.md", "docs//guide.md", "README.md\nMakefile",
                     "docs/examples/aerospace.toml"]:
            with self.subTest(path=path):
                self.assertFalse(content_only(["README.md", path]))
        self.assertFalse(content_only([]))


class GitScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hypermug-ci-scope-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("README.md", "guide\n")
        self.write("Source/HyperMug/Sources/Core/Engine.swift", "app source\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "--allow-empty", "-m", "test: fixture")
        return self.git("rev-parse", "HEAD")

    def native(self, event="push", base=None, head=None):
        return native_required(event, base or self.base, head or self.git("rev-parse", "HEAD"), cwd=self.root)

    def test_docs_and_cask_updates_use_lightweight_checks(self):
        for path in ["docs/new guide.md", "Casks/hypermug.rb", "Source/Website/a\nb.css"]:
            self.write(path, "new metadata\n")
        self.commit()
        self.assertFalse(self.native())

    def test_code_mixed_with_docs_requires_native(self):
        self.write("README.md", "updated guide\n")
        self.write("Source/HyperMug/Sources/Core/Engine.swift", "updated source\n")
        self.commit()
        self.assertTrue(self.native())

    def test_rename_from_code_to_docs_cannot_hide_native_change(self):
        (self.root / "docs").mkdir()
        self.git("mv", "Source/HyperMug/Sources/Core/Engine.swift", "docs/moved.md")
        self.commit()
        self.assertTrue(self.native())

    def test_rename_into_code_cannot_hide_native_change(self):
        self.git("mv", "README.md", "Source/HyperMug/Sources/Core/New.swift")
        self.commit()
        self.assertTrue(self.native())

    def test_deleted_code_requires_native_but_deleted_docs_do_not(self):
        self.git("rm", "README.md")
        docs_head = self.commit()
        self.assertFalse(self.native())
        self.git("rm", "Source/HyperMug/Sources/Core/Engine.swift")
        self.commit()
        self.assertTrue(self.native(base=docs_head))

    def test_pr_range_includes_changes_before_its_last_commit(self):
        self.write("Source/HyperMug/Sources/Core/Engine.swift", "changed source\n")
        self.commit()
        self.write("README.md", "doc followup\n")
        self.commit()
        self.assertTrue(self.native(event="pull_request"))

    def test_pr_uses_merge_base_when_main_has_diverged(self):
        self.git("checkout", "-b", "feature")
        self.write("README.md", "PR docs\n")
        head = self.commit()
        self.git("checkout", "main")
        self.write("Source/HyperMug/Sources/Core/Engine.swift", "approved main change\n")
        main = self.commit()
        self.assertFalse(self.native(event="pull_request", base=main, head=head))
        self.assertTrue(self.native(event="push", base=main, head=head))

    def test_manual_unknown_empty_or_missing_ranges_keep_full_checks(self):
        self.write("README.md", "updated guide\n")
        head = self.commit()
        for event, base, end in [
            ("workflow_dispatch", self.base, head), ("unknown", self.base, head),
            ("push", "0" * 40, head), ("push", "a" * 40, head),
            ("push", self.base, self.base), ("push", "", head),
            ("push", "main", head), ("push", self.base, "HEAD"),
        ]:
            with self.subTest(event=event, base=base, head=end):
                self.assertTrue(native_required(event, base, end, cwd=self.root))

    def test_woodpecker_reports_content_only_and_runs_native_for_source_pr(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("  - event: pull_request\n", workflow)
        self.assertNotIn("    path:", workflow)
        self.assertIn("./helpers/woodpecker-ci.sh native-checks", workflow)

        self.git("remote", "add", "origin", str(self.root))
        self.git("checkout", "-b", "feature")
        helpers = self.root / "helpers"
        helpers.mkdir()
        for name in ["woodpecker-ci.sh", "ci_scope.py"]:
            shutil.copyfile(WORKFLOW.parents[1] / "helpers" / name, helpers / name)
        self.write("helpers/woodpecker-macos-env.sh", "echo loaded-native-environment\n")
        self.write("helpers/check-dev-bundle.sh", "#!/bin/bash\necho checked-bundle\n")
        (helpers / "check-dev-bundle.sh").chmod(0o755)
        self.write("Makefile", "test test-runtime compile-check dev:\n\t@echo ran-$@\n")
        self.write("docs/guides/setup.md", "changed guide\n")
        self.git("add", "docs")
        self.git("commit", "-m", "docs: fixture")
        env = dict(os.environ, CI_PIPELINE_EVENT="pull_request", CI_REPO_DEFAULT_BRANCH="main",
                   CI_COMMIT_TARGET_BRANCH="main")

        def run(head, **override):
            return subprocess.run(["bash", "helpers/woodpecker-ci.sh", "native-checks"],
                                  cwd=self.root, env={**env, "CI_COMMIT_SHA": head, **override},
                                  capture_output=True, text=True, check=True).stdout

        docs_head = self.git("rev-parse", "HEAD")
        self.assertEqual(run(docs_head), "Content-only change. Native checks are skipped.\n")
        self.assertIn("ran-test\n", run(docs_head, CI_COMMIT_TARGET_BRANCH="missing"))
        self.write("Source/HyperMug/Sources/Core/Engine.swift", "changed source\n")
        self.git("add", "Source")
        self.git("commit", "-m", "fix: fixture")
        output = run(self.git("rev-parse", "HEAD"))
        for check in ["ran-test", "ran-test-runtime", "ran-compile-check", "ran-dev", "checked-bundle"]:
            self.assertIn(check + "\n", output)

    def test_cli_emits_one_boolean_output(self):
        self.write("README.md", "updated guide\n")
        head = self.commit()
        output = self.root / "output"
        script = Path(__file__).with_name("ci_scope.py").resolve()
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output)):
            result = subprocess.run([os.sys.executable, str(script), "--event", "push",
                                     "--base", self.base, "--head", head], cwd=self.root,
                                    capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, "native=false\n")
        self.assertEqual(output.read_text(), "native=false\n")


if __name__ == "__main__":
    unittest.main()
