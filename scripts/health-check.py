#!/usr/bin/env python3
"""Poll the middleware application's readiness endpoint without extra packages."""

from __future__ import annotations

import argparse
import json
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def check_once(url: str, timeout: float) -> tuple[bool, str]:
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "middleware-lab-health-check/1.0"})
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
            if response.status != 200:
                return False, f"HTTP {response.status}"
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                return False, "response was not valid JSON"
            if not isinstance(payload, dict) or payload.get("status") != "UP":
                return False, f"application status was not UP (body={body[:200]!r})"
            return True, "HTTP 200 and application status UP"
    except HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except (URLError, TimeoutError, OSError) as exc:
        return False, f"request failed: {exc}"


def positive_number(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive number") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive number")
    return number


def positive_integer(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Application readiness URL")
    parser.add_argument("--timeout", type=positive_number, default=5.0, help="Per-request timeout in seconds")
    parser.add_argument("--interval", type=float, default=5.0, help="Seconds between attempts (zero is allowed)")
    parser.add_argument("--attempts", type=positive_integer, default=12, help="Maximum number of attempts")
    args = parser.parse_args(argv)

    parsed = urlsplit(args.url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        parser.error("--url must be an http(s) URL with a hostname and no embedded credentials")
    if args.interval < 0:
        parser.error("--interval must be zero or greater")

    for attempt in range(1, args.attempts + 1):
        healthy, detail = check_once(args.url, args.timeout)
        label = "INFO" if healthy else "WARN"
        print(f"[{label}] attempt {attempt}/{args.attempts}: {detail}", flush=True)
        if healthy:
            print("[INFO] health check passed", flush=True)
            return 0
        if attempt < args.attempts:
            time.sleep(args.interval)

    print("[ERROR] health check failed after all attempts", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
