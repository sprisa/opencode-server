#!/usr/bin/env python3
"""Offline integration tests for release discovery, updating, publishing, and notes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent


class ReleaseAutomationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opencode-releases-")
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)
        shutil.copy(ROOT / "Taskfile.yml", self.cwd)
        shutil.copytree(ROOT / "scripts", self.cwd / "scripts")
        (self.cwd / "version.txt").write_text("2.2.4\n")
        (self.cwd / "version-v1.txt").write_text("1.19.5\n")
        self.bin = self.cwd / "bin"
        self.bin.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "GIT_AUTHOR_NAME": "Release Test",
            "GIT_COMMITTER_NAME": "Release Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_EMAIL": "test@example.com",
            "GH_CALLS": str(self.cwd / "gh-calls.jsonl"),
            "DOCKER_CALLS": str(self.cwd / "docker-calls.jsonl"),
            "RELEASE_FIXTURE": str(self.cwd / "releases.json"),
            "RELEASE_EXISTS": "0",
            "API_FAIL": "0",
        }
        self.mock("gh", '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["GH_CALLS"], "a") as out:
    out.write(json.dumps(args) + "\\n")
if args[0] == "api":
    if os.environ["API_FAIL"] == "1":
        sys.exit("upstream request failed")
    assert "--paginate" in args and "--slurp" in args, args
    with open(os.environ["RELEASE_FIXTURE"]) as fixture:
        print(fixture.read())
elif args[:2] == ["auth", "status"]:
    pass
elif args[:2] == ["release", "view"]:
    sys.exit(0 if os.environ["RELEASE_EXISTS"] == "1" else 1)
elif args[:2] != ["release", "create"]:
    sys.exit("unexpected gh call: " + repr(args))
''')
        self.mock("docker", '''
import json, os, sys
with open(os.environ["DOCKER_CALLS"], "a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\\n")
''')
        self.run_command("git", "init", "-q")
        self.run_command("git", "add", "version.txt", "version-v1.txt")
        self.run_command("git", "commit", "-qm", "feat: initial release")
        self.sha = self.run_command("git", "rev-parse", "HEAD").stdout.strip()
        # The supported v1 release is on page two; unrelated component releases
        # fill page one. Numeric versions and API order intentionally disagree.
        page_one = [self.release(f"process-daemon-v0.0.{i}") for i in range(95)]
        page_one += [
            self.release("v2.2.8"),
            self.release("v2.100.0", prerelease=True),
            self.release("v2.99.0", draft=True),
            self.release("v2.98.0-beta.1"),
            self.release("v2.97.0+build"),
        ]
        self.fixture([page_one, [self.release("v1.19.5"), self.release("v2.10.0"), self.release("v1.19.10")]])

    @staticmethod
    def release(tag, **fields):
        return {"tag_name": tag, "draft": False, "prerelease": False, **fields}

    def fixture(self, pages):
        (self.cwd / "releases.json").write_text(json.dumps(pages))

    def mock(self, name, source):
        script = self.bin / name
        script.write_text("#!/usr/bin/env python3\n" + source)
        script.chmod(0o755)

    def run_command(self, *args, check=True):
        return subprocess.run(args, cwd=self.cwd, env=self.env, text=True,
                              capture_output=True, check=check)

    def calls(self, name):
        path = self.cwd / f"{name}-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_discovery_paginates_and_selects_highest_stable_version(self):
        result = self.run_command("bash", "scripts/latest-releases.sh")
        self.assertEqual(json.loads(result.stdout), {"v1": "1.19.10", "v2": "2.10.0"})

    def test_discovery_reports_missing_supported_track(self):
        self.fixture([[self.release("v2.2.4")]])
        result = self.run_command("bash", "scripts/latest-releases.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No stable v1 release", result.stderr)

    def test_update_advances_both_pins_numerically(self):
        self.run_command("task", "update")
        self.assertEqual((self.cwd / "version.txt").read_text(), "2.10.0\n")
        self.assertEqual((self.cwd / "version-v1.txt").read_text(), "1.19.10\n")

    def test_update_never_downgrades_a_pin(self):
        (self.cwd / "version.txt").write_text("2.11.0\n")
        self.run_command("task", "update")
        self.assertEqual((self.cwd / "version.txt").read_text(), "2.11.0\n")

    def test_api_failure_does_not_silently_change_pins(self):
        self.env["API_FAIL"] = "1"
        result = self.run_command("task", "update", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.cwd / "version.txt").read_text(), "2.2.4\n")
        self.assertEqual((self.cwd / "version-v1.txt").read_text(), "1.19.5\n")

    def test_publish_pushes_both_tracks_and_sets_release_target_and_latest(self):
        self.run_command("task", "publish")
        docker = self.calls("docker")
        self.assertEqual(len(docker), 2)
        tags = lambda args: [args[i + 1] for i, arg in enumerate(args) if arg == "-t"]
        self.assertEqual(tags(docker[0]), ["docker.io/sprisa/opencode:2.2.4", "docker.io/sprisa/opencode:latest", "docker.io/sprisa/opencode:v2"])
        self.assertEqual(tags(docker[1]), ["docker.io/sprisa/opencode:1.19.5", "docker.io/sprisa/opencode:v1"])
        releases = [args for args in self.calls("gh") if args[:2] == ["release", "create"]]
        self.assertEqual(len(releases), 2)
        self.assertIn("--latest", releases[0])
        self.assertIn("--latest=false", releases[1])
        for args in releases:
            self.assertEqual(args[args.index("--target") + 1], self.sha)
            self.assertEqual(args[args.index("--repo") + 1], "sprisa/opencode-server")

    def test_existing_releases_are_retained_while_image_aliases_are_refreshed(self):
        self.env["RELEASE_EXISTS"] = "1"
        self.run_command("task", "publish")
        self.assertEqual(len(self.calls("docker")), 2)
        self.assertFalse(any(args[:2] == ["release", "create"] for args in self.calls("gh")))

    def test_release_notes_select_only_older_tags_in_current_history(self):
        for tag in ["v1.19.5", "v2.2.3", "v2.2.4", "v2.10.0", "v3.0.0"]:
            self.run_command("git", "tag", tag)
        other = self.run_command("git", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "feat: unmerged release").stdout.strip()
        self.run_command("git", "tag", "v2.2.5", other)
        for version, previous in [("v2.2.4", "v2.2.3"), ("v2.2.6", "v2.2.4"),
                                  ("v1.19.6", "v1.19.5"), ("v2.0.0", "v1.19.5")]:
            with self.subTest(version=version):
                notes = self.run_command("bash", "scripts/release-notes.sh", version).stdout
                self.assertIn(f"/compare/{previous}...{version}", notes)


if __name__ == "__main__":
    unittest.main()
