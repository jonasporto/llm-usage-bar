#!/usr/bin/env python3
"""llm-usage-bar usage adapter (example).

Install without cloning the repo:

  curl -fsSL https://raw.githubusercontent.com/jonasporto/llm-usage-bar/main/docs/usage-adapter.example.sh \\
    -o ~/.local/bin/example-usage
  chmod +x ~/.local/bin/example-usage

The menu bar app launches this file directly (no shell), with:

  argv:   --home <isolation directory>
  env:    LLM_USAGE_HOME      same directory as --home
          LLM_USAGE_PROVIDER  the profiles.json "provider" string

Print ONE JSON object to stdout and exit 0. Never print tokens, cookies or
Authorization values. On auth failure exit 2; on any other error exit 1.

Replace the demo body with a fetch against your own usage API.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def die(message, status=1):
    print(message, file=sys.stderr)
    sys.exit(status)


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--home")
    args, _ = parser.parse_known_args()
    home = args.home or os.environ.get("LLM_USAGE_HOME")
    if not home:
        die("missing --home / LLM_USAGE_HOME")
    return Path(home).expanduser()


def demo_snapshot(home: Path) -> dict:
    """Stand-in data so the adapter is testable before you wire a real API.

    Optional local override: $LLM_USAGE_HOME/usage.json with the same shape
    as the object this function returns.
    """
    override = home / "usage.json"
    if override.is_file():
        return json.loads(override.read_text())

    reset = datetime.now(timezone.utc).replace(
        hour=14, minute=0, second=0, microsecond=0
    )
    return {
        "account": f"{home.name} · demo",
        "windows": [
            {
                "id": "primary",
                "label": "5h window",
                "utilization": 28,
                "resetsAt": reset.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "durationMinutes": 300,
                "isPrimary": True,
            },
            {
                "id": "model-pro",
                "label": "Pro Model",
                "utilization": 64,
                "resetsAt": reset.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "durationMinutes": 1440,
            },
            {
                "id": "model-flash",
                "label": "Flash Model",
                "utilization": 15,
                "resetsAt": reset.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "durationMinutes": 1440,
            },
        ],
    }


def live_snapshot(home: Path) -> dict:
    """Example of a real fetch. Fill in URL, token source and JSON mapping.

    token = (home / "auth.json")  # read a field; do not print it
    request = urllib.request.Request(
        "https://api.example.com/v1/usage",
        headers={"Authorization": "Bearer " + token, "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
    return {
        "account": payload["email"],
        "windows": [{
            "id": "primary",
            "label": "Weekly",
            "utilization": payload["usedPercent"],
            "resetsAt": payload["resetsAt"],
            "isPrimary": True,
        }],
    }
    """
    raise NotImplementedError


def main():
    home = parse_args()
    if not home.is_dir():
        die(f"provider home does not exist: {home}", 2)
    try:
        snapshot = demo_snapshot(home)
        # snapshot = live_snapshot(home)
    except FileNotFoundError:
        die("not signed in — write credentials under the provider home", 2)
    json.dump(snapshot, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
