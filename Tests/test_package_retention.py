import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("retention", Path(__file__).parents[1] / "Scripts/prune-packages.py")
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class PackageRetentionTests(unittest.TestCase):
    def test_parallel_finishes_and_reruns_use_build_number_first(self):
        completed = [(49, 800, True), (50, 750, True), (50, 775, True)]
        self.assertEqual(retention.superseded_artifacts(completed, 50), [800, 750])

    def test_older_ci_copy_does_not_substitute_for_the_published_build(self):
        self.assertEqual(retention.superseded_artifacts([(49, 800, True)], 50), [800])

    def test_unreleased_success_is_kept_when_a_later_build_failed(self):
        self.assertEqual(retention.superseded_artifacts([(50, 10, True), (51, 20, True), (52, 30, False)], 50), [10])
