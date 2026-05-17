#!/bin/bash
# Check for updates to torrents for our mirror
# https://mirror.tsue.net/
#
# This script runs once an hour via cron and raises an alert via healthchecks.io
# We send the output as a POST to /fail in the event of a non-zero exit.

# Current versions - alert when these go missing from the upstream mirror
ARCH='2026.05.01'
CACHY='260426'
DEBIAN='13.5.0'
FEDORA_VERSIONS='42 43 44'
MINT='22.3'
PROXMOX6='6.4-1'
PROXMOX7='7.4-1'
PROXMOX8='8.4-1'
PROXMOX9='9.1-1'

# Upcoming versions - alert when these appear on the upstream mirror
ALMA8='8.11'
ALMA9='9.8'
ALMA10='10.2'
ALMA11='11.0'

# Where transmission stores downloaded torrents
ISO_DIR='/var/lib/transmission/Downloads'

# Mirror status page; the bottom of this file is transmission-remote -l output
STATUS_FILE="${ISO_DIR}/status.txt"

# Number of consecutive curl failures before a domain is reported as down.
# Transient outages are silently ignored until this threshold is reached.
FAIL_THRESHOLD=3
FAIL_FILE='/tmp/new-torrents-failures.txt'

#############
# FUNCTIONS #
#############

# Add a distro name or domain to the UPDATES string, skipping duplicates.
#
# Usage: add_update NAME
#   NAME - distro name with an available update, or a domain reported as down,
#          or a prefixed alert such as MISSING:, STALE:, ORPHAN:, MALFORMED:,
#          NEW:, or DROPPED:.
UPDATES=''
add_update() {
  local NEW=$1

  # Skip if already present to avoid duplicate alerts
  grep -qFw "${NEW}" <<< "${UPDATES}" && return

  if [[ -z "${UPDATES}" ]]; then
    UPDATES="${NEW}"
  else
    UPDATES="${UPDATES} ${NEW}"
  fi
}

# Fetch a URL, storing the response in the global BODY variable.
# Tracks consecutive failures per name and alerts once FAIL_THRESHOLD is reached.
# Resets failure counters on success.
#
# Usage: fetch URL NAME1 PATTERN1 [NAME2 PATTERN2 ...]
#   URL             - the URL to fetch
#   NAME/PATTERN    - pairs used to track per-distro failure counts; PATTERN is
#                     unused by fetch itself but keeps the call signature consistent
#                     with check_distro so callers can pass "$@" through unchanged.
fetch() {
  local URL="${1}"
  shift
  local COUNT

  # Extract the domain for use in down-alerts
  DOMAIN=$(awk -F[/:] '{print $4}' <<< "${URL}")

  # Fetch the URL; result is available globally as BODY
  BODY=$(curl --silent --max-time 10 --fail-with-body "${URL}")

  if [[ $? -ne 0 ]]; then
    BODY=""
    touch "${FAIL_FILE}"
    # Increment and check the failure counter for each name in the pair list
    while [[ $# -ge 2 ]]; do
      local NAME="${1}"
      shift 2
      COUNT=$(grep "^${NAME}=" "${FAIL_FILE}" | cut -d= -f2)
      COUNT=$(( ${COUNT:-0} + 1 ))
      if grep -q "^${NAME}=" "${FAIL_FILE}"; then
        sed -i "s/^${NAME}=.*/${NAME}=${COUNT}/" "${FAIL_FILE}"
      else
        echo "${NAME}=${COUNT}" >> "${FAIL_FILE}"
      fi
      [[ "${COUNT}" -ge "${FAIL_THRESHOLD}" ]] && add_update "${DOMAIN}"
    done
    return 1
  fi

  # On success, reset failure counters for all names if the fail file has data
  [[ ! -s "${FAIL_FILE}" ]] && return 0
  while [[ $# -ge 2 ]]; do
    local NAME="${1}"
    shift 2
    if grep -q "^${NAME}=" "${FAIL_FILE}"; then
      sed -i "s/^${NAME}=.*/${NAME}=0/" "${FAIL_FILE}"
    fi
  done
}

# Validate that BODY is non-empty and meets a minimum length threshold.
# A suspiciously short response usually indicates a transient error page or
# a structural change upstream rather than genuine content.
# Alerts on ALERT_NAME and returns 1 so the caller can early-return via || return 1.
#
# Usage: body_ok ALERT_NAME [MIN_LEN]
#   ALERT_NAME - passed to add_update if the check fails
#   MIN_LEN    - minimum acceptable byte length; defaults to 250 if omitted
body_ok() {
  local ALERT_NAME="${1}" MIN_LEN="${2:-250}"
  if [[ -z "${BODY}" || ${#BODY} -lt ${MIN_LEN} ]]; then
    add_update "${ALERT_NAME}"
    return 1
  fi
}

# Fetch a distro page and check name/pattern pairs against the response.
# Supports checking multiple versions in a single fetch (e.g. all Proxmox releases).
#
# Usage: check_distro URL MATCH NAME1 PATTERN1 [NAME2 PATTERN2 ...]
#   URL   - page to fetch
#   MATCH - "missing": alert when pattern is absent (current release check)
#           "present": alert when pattern appears (upcoming release check)
#   Remaining args are name/pattern pairs checked against the fetched page.
check_distro() {
  local URL="${1}" MATCH="${2}"
  shift 2

  fetch "${URL}" "$@" || return 1

  # A very short response suggests an error page rather than real content
  body_ok "${DOMAIN}" || return 1

  while [[ $# -ge 2 ]]; do
    local NAME="${1}" PATTERN="${2}"
    shift 2

    if [[ "${MATCH}" = "missing" ]]; then
      # Alert when the expected version string is no longer present
      grep -q "${PATTERN}" <<< "${BODY}" || add_update "${NAME}"
    elif [[ "${MATCH}" = "present" ]]; then
      # Alert when an upcoming version string has appeared
      grep -q "${PATTERN}" <<< "${BODY}" && add_update "${NAME}"
    else
      echo "ERROR: Unsupported check_distro match type '${MATCH}'. Exiting."
      exit 1
    fi
  done
}

# Walk the tracker torrents for a single Fedora version and compare against
# local disk and transmission status. Called only for versions confirmed present
# on both the tracker and in FEDORA_VERSIONS.
#
# Usage: check_fedora_version VER VER_TORRENTS
#   VER          - the Fedora version number (e.g. 44)
#   VER_TORRENTS - newline-separated list of .torrent filenames for VER
check_fedora_version() {
  local VER="${1}" VER_TORRENTS="${2}"

  # Check each tracker torrent against transmission status and local disk
  while IFS= read -r TORRENT; do
    # Match against the torrent directories of the same name, minus .torrent
    local DIR="${TORRENT%.torrent}"

    # Transmission already knows about this torrent; nothing to do
    "${HAS_STATUS}" && grep -qF "${DIR}" "${STATUS_FILE}" && continue

    if [[ -d "${ISO_DIR}/${DIR}" ]]; then
      # Directory exists locally but transmission has no record of it
      "${HAS_STATUS}" && add_update "ORPHAN:${DIR}"
    else
      # Not on disk and not in transmission; needs to be downloaded
      add_update "MISSING:${DIR}"
    fi
  done <<< "${VER_TORRENTS}"

  # Check for local directories for this version no longer listed on the tracker.
  # The glob is scoped to -${VER}/ to avoid matching other versions.
  LOCAL_FEDORA=("${ISO_DIR}"/Fedora-*-"${VER}"/)
  [[ -d "${LOCAL_FEDORA[0]}" ]] || return 0

  for DIR in "${LOCAL_FEDORA[@]}"; do
    DIR=$(basename "${DIR%/}")
    local TORRENT="${DIR}.torrent"
    # Still on the tracker; nothing to do
    grep -qF "${TORRENT}" <<< "${VER_TORRENTS}" && continue
    # Present locally but removed from the tracker
    add_update "STALE:${DIR}"
  done
}

########
# MAIN #
########

# Bail early if the download directory is missing
if [[ ! -d "${ISO_DIR}" ]]; then
  echo "ERROR: transmission download directory ${ISO_DIR} is missing. Exiting."
  exit 1
# Also bail early if jq is missing
elif ! jq --help &> /dev/null; then
  echo "ERROR: Please install jq to proceed. Exiting."
  exit 1
fi

# Validate status.txt before use; fall back to filesystem-only checks if absent
# or malformed, and raise an alert so the issue is visible in the report.
HAS_STATUS=true
if [[ ! -s "${STATUS_FILE}" ]]; then
  add_update "MISSING:status.txt"
  HAS_STATUS=false
elif ! grep -q "^Sum:" "${STATUS_FILE}"; then
  add_update "MALFORMED:status.txt"
  HAS_STATUS=false
fi

# Enable bash trace output for interactive debugging
[[ "${1}" == "--debug" ]] && set -x

# Simple page-scrape checks: fetch each URL once and look for the version string
check_distro "https://mirror.rackspace.com/archlinux/iso/latest/"          missing  "Arch"       "${ARCH}"
check_distro "https://cachyos.org/download/"                               missing  "CachyOS"    "${CACHY}"
check_distro "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"  missing  "Debian"     "${DEBIAN}"
check_distro "https://linuxmint.com/download.php"                          missing  "Linux Mint" "${MINT}"

# Single fetch for all four Proxmox versions
check_distro "https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso" missing \
  "Proxmox 6" "${PROXMOX6}" \
  "Proxmox 7" "${PROXMOX7}" \
  "Proxmox 8" "${PROXMOX8}" \
  "Proxmox 9" "${PROXMOX9}"

# Single fetch for all tracked and upcoming Alma versions
check_distro "https://mirror.rackspace.com/almalinux/" present \
  "Alma 8"  "${ALMA8}"  \
  "Alma 9"  "${ALMA9}"  \
  "Alma 10" "${ALMA10}" \
  "Alma 11" "${ALMA11}"

# Fedora torrent check - compare tracker JSON to local disk and transmission status.
#
# Fedora publishes a JSON of all active torrents at torrent.fedoraproject.org making it
# straightforward to detect version-level changes without scraping multiple pages.
#
# Each torrent unpacks into a subdirectory named after the torrent file (minus
# the .torrent suffix), so directory presence is used instead of ISO filename matching.
#
# Version-level alerts (one alert per event, not one per torrent):
#   NEW:Fedora-VER     - a version not in FEDORA_VERSIONS appeared on the tracker
#   DROPPED:Fedora-VER - a version in FEDORA_VERSIONS is no longer on the tracker
#
# Per-torrent alerts (only for versions present in both FEDORA_VERSIONS and tracker):
#   MISSING:DIR  - torrent directory absent from disk and unknown to transmission
#   ORPHAN:DIR   - torrent directory present on disk but unknown to transmission
#   STALE:DIR    - torrent directory present on disk but removed from the tracker

fetch "https://torrent.fedoraproject.org/torrents.json" "Fedora" "notused"

if [[ $? -eq 0 ]]; then
  # Extract the sorted list of release version names currently on the tracker
  FEDORA_TRACKER_VERSIONS=$(jq -r '.[].name' <<< "${BODY}" | sort -V)

  if [[ -z "${FEDORA_TRACKER_VERSIONS}" ]]; then
    add_update "MALFORMED:Fedora Tracker"
  else
    # Alert if we find version(s) not listed in FEDORA_VERSIONS (new release)
    while IFS= read -r VER; do
      grep -qw "${VER}" <<< "${FEDORA_VERSIONS}" && continue
      add_update "NEW:Fedora-${VER}"
    done <<< "${FEDORA_TRACKER_VERSIONS}"

    # Alert if we find version(s) in FEDORA_VERSIONS missing (EOL'd release)
    for VER in ${FEDORA_VERSIONS}; do
      if ! grep -qw "${VER}" <<< "${FEDORA_TRACKER_VERSIONS}"; then
        add_update "DROPPED:Fedora-${VER}"
        continue
      fi

      # Version is present on both sides; check the individual torrents
      FEDORA_VER_TORRENTS=$(jq -r --arg V "${VER}" \
        '.[] | select(.name == $V) | .torrents[].torrent' <<< "${BODY}" | sort)
      check_fedora_version "${VER}" "${FEDORA_VER_TORRENTS}"
    done
  fi
fi

# Ubuntu ISO check - compare tracker to local disk and transmission status.
#
# Ubuntu releases ISOs frequently and names them inconsistently across point
# releases, so we scrape all active non-beta, non-snapshot ISO names from the
# official tracker and compare against local disk rather than tracking versions.
#
# Per-ISO alerts:
#   MISSING:ISO          - tracker ISO absent from disk and unknown to transmission
#   ORPHAN:ISO           - tracker ISO present on disk but unknown to transmission
#   STALE:ISO            - local ubuntu-*.iso no longer listed on the tracker
#   MISSING:ubuntu-*.iso - no Ubuntu ISOs found on our disk at all

fetch "https://torrent.ubuntu.com/tracker_index" "Ubuntu" "notused"

if [[ $? -eq 0 ]]; then
  UBUNTU_TRACKER=$(grep -vE "beta|snapshot" <<< "${BODY}" | grep -oP '(?<=>)[^<]+\.iso(?=<)')

  if [[ -z "${UBUNTU_TRACKER}" ]]; then
    add_update "MALFORMED:Ubuntu Tracker"
  else
    # Alert on tracker ISOs missing from local disk or unknown to transmission
    while IFS= read -r ISO; do
      "${HAS_STATUS}" && grep -qF "${ISO}" "${STATUS_FILE}" && continue
      if [[ -s "${ISO_DIR}/${ISO}" ]]; then
        # ISO is on disk but transmission has no record of it
        "${HAS_STATUS}" && add_update "ORPHAN:${ISO}"
      else
        # Not on disk and not in transmission; needs to be downloaded
        add_update "MISSING:${ISO}"
      fi
    done <<< "${UBUNTU_TRACKER}"

    # Alert on local ubuntu-*.iso files no longer listed on the tracker
    LOCAL_ISOS=("${ISO_DIR}"/ubuntu-*.iso)
    if [[ ! -s "${LOCAL_ISOS[0]}" ]]; then
      # The glob matched nothing; no Ubuntu ISOs on disk at all
      add_update "MISSING:ubuntu-*.iso"
    else
      for FILE in "${LOCAL_ISOS[@]}"; do
        ISO=$(basename "${FILE}")
        # Still on the tracker; nothing to do
        grep -qF "${ISO}" <<< "${UBUNTU_TRACKER}" && continue
        # Present locally but removed from the tracker
        add_update "STALE:${ISO}"
      done
    fi
  fi
fi

# Report any alerts if present and exit non-zero
if [[ -n "${UPDATES}" ]]; then
  echo "${UPDATES}"
  exit 1
fi

# All checks passed
exit 0
