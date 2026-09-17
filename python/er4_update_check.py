#!/usr/bin/env python3
# A simple script to monitor for EdgeRouter 4 (ER-4) firmware updates.
#
# The page https://www.ui.com/download/software/er-4 is a JavaScript app, so
# instead of scraping its HTML we query the JSON API the page itself uses.
#
# Usage:
#   ./er4_update_check.py          # exit 1 (and print) if a newer version exists
#   ./er4_update_check.py -u       # update ~/.config/er4.conf to the latest
import argparse
import json
import os
import sys
import urllib.request

CONFIG_PATH = os.path.expanduser("~/.config/er4.conf")
API_URL = "https://download.svc.ui.com/v1/downloads/products/slugs/er-4"


def fetch_latest_release():
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        ),
        "Accept": "application/json",
    }
    req = urllib.request.Request(API_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode("utf-8", errors="ignore"))
    except Exception as e:
        sys.stderr.write(f"Error fetching ER-4 firmware data: {e}\n")
        sys.exit(2)

    try:
        downloads = data["downloads"]
        # API returns the list newest-first; max() by date keeps us safe
        # in case the ordering ever changes.
        latest = max(downloads, key=lambda d: d.get("date_published") or "")
        version = latest["version"]
        release_date = latest["date_published"]
    except (KeyError, IndexError, TypeError, ValueError) as e:
        sys.stderr.write(
            f"Error: Could not parse latest ER-4 firmware from API response: {e}\n"
        )
        sys.exit(2)

    return version, release_date


def read_stored_version():
    if not os.path.exists(CONFIG_PATH):
        return None

    stored = {}
    try:
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                if "=" in line:
                    key, val = line.strip().split("=", 1)
                    stored[key] = val.strip('"').strip("'")
    except (OSError, UnicodeDecodeError) as e:
        sys.stderr.write(f"Error reading {CONFIG_PATH}: {e}\n")
        sys.exit(2)
    return stored.get("ER4_VERSION")


def write_config(version, release_date):
    try:
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            f.write(f'ER4_VERSION="{version}"\n')
            f.write(f'ER4_RELEASE_DATE="{release_date}"\n')
    except OSError as e:
        sys.stderr.write(f"Error writing {CONFIG_PATH}: {e}\n")
        sys.exit(2)


def main():
    parser = argparse.ArgumentParser(
        description="Check for new EdgeRouter 4 (ER-4) firmware releases."
    )
    parser.add_argument(
        "-u",
        "--update",
        action="store_true",
        help=f"Update {CONFIG_PATH} to match the latest online version.",
    )
    args = parser.parse_args()

    latest_version, release_date = fetch_latest_release()

    # If --update is passed, sync config to latest and exit 0
    if args.update:
        write_config(latest_version, release_date)
        print(f"Updated {CONFIG_PATH} to v{latest_version} ({release_date})")
        sys.exit(0)

    stored_version = read_stored_version()

    # First run: store latest version silently and exit 0
    if stored_version is None:
        write_config(latest_version, release_date)
        sys.exit(0)

    # Compare versions
    if latest_version != stored_version:
        print(f"ER-4 firmware v{latest_version} (Released: {release_date})")
        sys.exit(1)

    # Matching versions: exit silently with 0
    sys.exit(0)


if __name__ == "__main__":
    main()
