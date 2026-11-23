#!/usr/bin/env python3
"""Verify that a requested artifact comes from a successful trusted CI run."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


TRUSTED_BRANCHES = {"main", "dev"}
TRUSTED_EVENTS = {"push", "workflow_dispatch"}
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"


def validate_run(run: dict, expected_repo: str, expected_run_id: str) -> None:
    if str(run.get("id")) != expected_run_id:
        raise ValueError("workflow run ID does not match the requested run")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError("source CI run must be completed successfully")
    if run.get("event") not in TRUSTED_EVENTS:
        raise ValueError("artifact source must be a push or manual CI run, not a pull request")
    if run.get("head_branch") not in TRUSTED_BRANCHES:
        raise ValueError("artifact source branch must be main or dev")
    # The workflow-runs API returns the workflow file path suffixed with @ref
    # (for example, .github/workflows/ci.yml@main).
    if str(run.get("path", "")).split("@", 1)[0] != CI_WORKFLOW_PATH:
        raise ValueError("artifact must come from the repository CI workflow")
    repo = (run.get("repository") or {}).get("full_name")
    head_repo = (run.get("head_repository") or {}).get("full_name")
    if repo != expected_repo or head_repo != expected_repo:
        raise ValueError("artifact must come from this repository, not a fork or another repository")
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", str(run.get("head_sha", ""))):
        raise ValueError("source CI run has an invalid commit SHA")


def validate_artifacts(artifacts_response: dict, artifact_name: str) -> dict:
    matching = [item for item in artifacts_response.get("artifacts", []) if item.get("name") == artifact_name]
    if len(matching) != 1:
        raise ValueError(f"expected exactly one artifact named {artifact_name!r}")
    artifact = matching[0]
    if artifact.get("expired") is True:
        raise ValueError("requested CI artifact has expired")
    if int(artifact.get("size_in_bytes", 0)) <= 0:
        raise ValueError("requested CI artifact is empty")
    return artifact


def api_get(url: str, token: str) -> dict:
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "middleware-devops-lab-artifact-verifier",
        },
    )
    with urlopen(request, timeout=15) as response:
        return json.load(response)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--artifact-name", default="middleware-demo")
    parser.add_argument("--output", type=Path, required=True, help="Write verified source metadata JSON here")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("--repo must be OWNER/REPOSITORY")
    if not args.run_id.isdigit():
        parser.error("--run-id must be a numeric GitHub Actions run ID")
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        parser.error("GH_TOKEN must be provided through the workflow environment")

    base = f"https://api.github.com/repos/{args.repo}/actions/runs/{args.run_id}"
    try:
        run = api_get(base, token)
        validate_run(run, args.repo, args.run_id)
        artifacts = api_get(f"{base}/artifacts?per_page=100", token)
        artifact = validate_artifacts(artifacts, args.artifact_name)
        metadata = {
            "run_id": str(run["id"]),
            "branch": run["head_branch"],
            "commit": run["head_sha"],
            "workflow_path": run["path"],
            "artifact_name": artifact["name"],
            "artifact_id": artifact["id"],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        print(f"[INFO] Trusted CI artifact verified: run={args.run_id}, branch={run['head_branch']}, commit={run['head_sha']}")
        return 0
    except (HTTPError, URLError, TimeoutError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"[ERROR] CI artifact verification failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
