import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tool" / "ci" / "test_shard.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "pr-quality.yml"
SPLIT_BY_TEST = "test/chat_screen_test.dart"


def shard(*args):
    out = subprocess.run(
        [str(SCRIPT), *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    return [line for line in out.splitlines() if line]


def matrix(job):
    """The `shard: [..]` list and the total the job's command passes."""
    text = WORKFLOW.read_text(encoding="utf-8")
    start = text.index(f"\n  {job}:\n")
    following = re.search(r"\n  [a-z_]+:\n", text[start + 1 :])
    body = text[start : start + 1 + following.start()] if following else text[start:]
    listed = re.search(r"shard: \[([0-9, ]+)\]", body)
    return [int(n) for n in listed.group(1).split(",")], body


class CiTestShardsTest(unittest.TestCase):
    """Splitting the suite must never drop a test file from CI."""

    def test_the_shards_cover_every_test_file_exactly_once(self):
        in_tree = sorted(
            path.relative_to(ROOT).as_posix()
            for path in (ROOT / "test").rglob("*_test.dart")
        )
        self.assertIn(SPLIT_BY_TEST, in_tree)
        self.assertGreater(len(in_tree), 1000)

        indexes, _ = matrix("tests")
        total = len(indexes)
        self.assertEqual(indexes, list(range(total)))
        dealt = [path for index in indexes for path in shard(str(index), str(total))]
        self.assertEqual(len(dealt), len(set(dealt)), "a file is in two shards")
        self.assertNotIn(SPLIT_BY_TEST, dealt)
        self.assertEqual(sorted(dealt + [SPLIT_BY_TEST]), in_tree)
        self.assertEqual(sorted(shard("all")), sorted(dealt))

    def test_the_split_is_even_and_the_same_every_time(self):
        indexes, _ = matrix("tests")
        total = len(indexes)
        sizes = [len(shard(str(index), str(total))) for index in indexes]
        self.assertLessEqual(max(sizes) - min(sizes), 1)
        self.assertEqual(shard("0", str(total)), shard("0", str(total)))

    def test_the_workflow_runs_every_shard_it_declares(self):
        indexes, body = matrix("tests")
        self.assertIn(
            f'tool/ci/test_shard.sh "${{{{ matrix.shard }}}}" {len(indexes)}', body
        )
        self.assertIn("flutter test --concurrency=1 -x opt-in", body)

        indexes, body = matrix("chat_screen_tests")
        self.assertEqual(indexes, list(range(len(indexes))))
        self.assertIn(f"--total-shards {len(indexes)}", body)
        self.assertIn('--shard-index "${{ matrix.shard }}"', body)
        self.assertIn(SPLIT_BY_TEST, body)
        self.assertIn("flutter test --concurrency=1 -x opt-in", body)

    def test_the_required_check_fails_unless_every_job_succeeded(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        start = text.index("\n  quality:\n")
        body = text[start:]
        self.assertIn("name: Analyze & Test", body)
        self.assertIn("needs: [checks, tests, chat_screen_tests]", body)
        self.assertIn("if: always()", body)
        for job in ("checks", "tests", "chat_screen_tests"):
            self.assertIn(f"needs.{job}.result", body)

    def test_bad_arguments_are_refused(self):
        for args in ([], ["0"], ["3", "3"], ["x", "2"], ["0", "0"], ["all", "1"]):
            done = subprocess.run(
                [str(SCRIPT), *args], cwd=ROOT, capture_output=True, text=True
            )
            self.assertEqual(done.returncode, 64, args)


if __name__ == "__main__":
    unittest.main()
