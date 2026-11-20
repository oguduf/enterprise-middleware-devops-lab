import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_ci_artifact", ROOT / "scripts" / "verify-ci-artifact.py")
verify_ci_artifact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify_ci_artifact)


def valid_run(**overrides):
    run = {
        "id": 12345,
        "status": "completed",
        "conclusion": "success",
        "event": "push",
        "head_branch": "dev",
        "path": ".github/workflows/ci.yml@dev",
        "repository": {"full_name": "oguduf/enterprise-middleware-devops-lab"},
        "head_repository": {"full_name": "oguduf/enterprise-middleware-devops-lab"},
        "head_sha": "a" * 40,
    }
    run.update(overrides)
    return run


class CiArtifactValidationTests(unittest.TestCase):
    def test_trusted_successful_push_run_is_accepted(self):
        verify_ci_artifact.validate_run(valid_run(), "oguduf/enterprise-middleware-devops-lab", "12345")

    def test_pull_request_artifact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "not a pull request"):
            verify_ci_artifact.validate_run(valid_run(event="pull_request"), "oguduf/enterprise-middleware-devops-lab", "12345")

    def test_fork_artifact_is_rejected(self):
        run = valid_run(head_repository={"full_name": "contributor/fork"})
        with self.assertRaisesRegex(ValueError, "not a fork"):
            verify_ci_artifact.validate_run(run, "oguduf/enterprise-middleware-devops-lab", "12345")

    def test_failed_ci_run_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "completed successfully"):
            verify_ci_artifact.validate_run(valid_run(conclusion="failure"), "oguduf/enterprise-middleware-devops-lab", "12345")

    def test_missing_or_expired_artifact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            verify_ci_artifact.validate_artifacts({"artifacts": []}, "middleware-demo")
        with self.assertRaisesRegex(ValueError, "expired"):
            verify_ci_artifact.validate_artifacts(
                {"artifacts": [{"name": "middleware-demo", "expired": True, "size_in_bytes": 10}]},
                "middleware-demo",
            )


if __name__ == "__main__":
    unittest.main()
