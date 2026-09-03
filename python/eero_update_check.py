#!/usr/bin/env python3
# A simple script to monitor for eero OS updates
import argparse
import html
import os
import re
import sys
import urllib.request

CONFIG_PATH = os.path.expanduser("~/.config/eero.conf")
URL = "https://eero.com/support/articles/eero-software-release-notes"


def fetch_latest_release():
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/120.0.0.0 Safari/537.36"
        )
    }
    req = urllib.request.Request(URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            raw_html = response.read().decode("utf-8", errors="ignore")
    except Exception as e:
        sys.stderr.write(f"Error fetching eero support page: {e}\n")
        sys.exit(2)

    # Strip HTML tags, unescape entities (&nbsp; etc), and collapse whitespace
    text = re.sub(r"<[^>]+>", " ", raw_html)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text)

    match = re.search(
        r"eeroOS:\s*(v[\d\.]+)\s*-\s*Released\s*([A-Za-z]+\s+\d+,\s+\d{4})", text
    )
    if not match:
        sys.stderr.write("Error: Could not parse eeroOS version from page.\n")
        sys.exit(2)

    version, release_date = match.group(1), match.group(2)
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
    return stored.get("EERO_VERSION")


def write_config(version, release_date):
    try:
        os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            f.write(f'EERO_VERSION="{version}"\n')
            f.write(f'EERO_RELEASE_DATE="{release_date}"\n')
    except OSError as e:
        sys.stderr.write(f"Error writing {CONFIG_PATH}: {e}\n")
        sys.exit(2)


def main():
    parser = argparse.ArgumentParser(
        description="Check for new eeroOS releases via web scraping."
    )
    parser.add_argument(
        "-u",
        "--update",
        action="store_true",
        help="Update ~/.config/eero.conf to match the latest online version.",
    )
    args = parser.parse_args()

    latest_version, release_date = fetch_latest_release()

    # If --update is passed, sync config to latest and exit 0
    if args.update:
        write_config(latest_version, release_date)
        print(f"Updated {CONFIG_PATH} to {latest_version} ({release_date})")
        sys.exit(0)

    stored_version = read_stored_version()

    # First run: store latest version silently and exit 0
    if stored_version is None:
        write_config(latest_version, release_date)
        sys.exit(0)

    # Compare versions
    if latest_version != stored_version:
        print(f"eeroOS {latest_version} (Released: {release_date})")
        sys.exit(1)

    # Matching versions: exit silently with 0
    sys.exit(0)


if __name__ == "__main__":
    main()
