#!/bin/bash
# Check for updates to torrents for our mirror
# https://mirror.tsue.net/
#
# This script runs once an hour via cron and raises an alert via healthchecks.io
# We send the output as a POST to /fail in the event of a non-zero exit.

# Current versions - alert when these go missing from the upstream mirror
ARCH='2026.04.01'
CACHY='260426'
DEBIAN='13.4.0'
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
FEDORA='45'

# Where transmission stores downloaded ISOs
ISO_DIR='/var/lib/transmission/Downloads'

# Mirror status page; the bottom of this file is transmission-remote -l output
STATUS_FILE="${ISO_DIR}/status.txt"

# Tracks consecutive curl failures per distro so transient outages
# are silently ignored but sustained ones get reported as NAME(DOWN).
FAIL_THRESHOLD=3
FAIL_FILE='/tmp/new-torrents-failures.txt'

#############
# FUNCTIONS #
#############

# Add an update (and domain failures) to our UPDATE string while avoiding dupes
#
# Usage: add_update NAME
#   NAME - The distro name that has an update available or a domain name that is down
#          or appears to have a malformed payload from an outage or a new page format.
UPDATES=''
add_update() {
  local NEW=$1
  
  # Check for duplicates and skip if it's already in our list
  grep -qFw "${NEW}" <<< "${UPDATES}" && return

  if [[ -z "${UPDATES}" ]]; then
    UPDATES="${NEW}"
  else
    # Add the update to our list
    UPDATES="${UPDATES} ${NEW}"
  fi
}

# Fetch a URL and track consecutive failures.
# On success, the response is stored in the global BODY variable.
# On failure, each NAME in the pair list is tracked and reported after threshold.
#
# Usage: fetch URL NAME1 PATTERN1 [NAME2 PATTERN2 ...]
#   The name/pattern pairs are passed through so fetch knows which names
#   to mark as (DOWN) if the server is unreachable.
fetch() {
  local URL="${1}"
  shift
  local COUNT

  # Resolve the domain from the URL for alerting purposes
  DOMAIN=$(awk -F[/:] '{print $4}' <<< "${URL}")

  # cURL with our options; exports as the global BODY variable
  BODY=$(curl --silent --max-time 10 --fail-with-body "${URL}")

  # Track and report any failures for the distro(s) associated with this URL
  if [[ $? -ne 0 ]]; then
    BODY=""
    touch "${FAIL_FILE}"
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
      if [[ "${COUNT}" -ge "${FAIL_THRESHOLD}" ]]; then
        add_update "${DOMAIN}"
      fi
    done
    return 1
  fi

  # curl succeeded -- reset failure counters for all names
  # if the FAIL_FILE is present with any data in it
  [[ ! -s "${FAIL_FILE}" ]] && return 0
  while [[ $# -ge 2 ]]; do
    local NAME="${1}"
    shift 2
    if grep -q "^${NAME}=" "${FAIL_FILE}"; then
      sed -i "s/^${NAME}=.*/${NAME}=0/" "${FAIL_FILE}"
    fi
  done
}

# Check a distro's download page for version strings.
# Calls fetch once, then checks each name/pattern pair against the response.
# Allows for checking multiple versions, most notably with Proxmox.
#
# Usage: check_distro URL MATCH NAME1 PATTERN1 [NAME2 PATTERN2 ...]
#   URL   - page to fetch with curl
#   MATCH - "missing": alert when pattern is absent (most distros)
#           "present": alert when pattern appears (e.g., Fedora next release)
#   Remaining args are name/pattern pairs to check against the fetched page.
check_distro() {
  local URL="${1}" MATCH="${2}"
  shift 2

  # Try to fetch our page
  fetch "${URL}" "$@" || return 1

  # If fetch() is really small, alert on the domain and keep moving. This is
  # mostly a safety net for Fedora but also avoids every Proxmox check from
  # triggering on a single failure.
  if [[ ${#BODY} -lt 250 ]]; then
    add_update "${DOMAIN}"
    return 1
  fi

  # Allows multiple sets per page, mostly for Proxmox currently
  while [[ $# -ge 2 ]]; do
    local NAME="${1}" PATTERN="${2}"
    shift 2

    # Look for the current release to go missing
    if [[ "${MATCH}" = "missing" ]]; then
      grep -q "${PATTERN}" <<< "${BODY}" || add_update "${NAME}"
    # Look for the upcoming release to be present
    elif [[ "${MATCH}" = "present" ]]; then
      grep -q "${PATTERN}" <<< "${BODY}" && add_update "${NAME}"
    else
      echo "ERROR: Unsupported check_distro match. Exiting."
      exit 1
    fi
  done
}

########
# MAIN #
########

# Bail early if the ISO directory is missing
if [[ ! -d "${ISO_DIR}" ]]; then
    echo "ERROR: our transmission directory ${ISO_DIR} is missing. Exiting."
    exit 1
fi

# Alert and fall back to filesystem-only Ubuntu checks if status.txt
# is missing or the transmission-remote data failed to populate
HAS_STATUS=true
if [[ ! -s "${STATUS_FILE}" ]]; then
    add_update "MISSING:status.txt"
    HAS_STATUS=false
elif ! grep -q "^Sum:" "${STATUS_FILE}"; then
    add_update "MALFORMED:status.txt"
    HAS_STATUS=false
fi

# Allow for quick debugging
[[ "${1}" == "--debug" ]] && set -x

# Run the checks
check_distro "https://mirror.rackspace.com/archlinux/iso/latest/"         missing  "Arch"       "${ARCH}"
check_distro "https://cachyos.org/download/"                              missing  "CachyOS"    "${CACHY}"
check_distro "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/" missing  "Debian"     "${DEBIAN}"
check_distro "https://mirror.rackspace.com/fedora/releases/"              present  "Fedora"     "${FEDORA}"
check_distro "https://linuxmint.com/download.php"                         missing  "Linux Mint" "${MINT}"

# Single fetch, check all four versions of Proxmox
check_distro "https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso" missing \
  "Proxmox 6" "${PROXMOX6}" \
  "Proxmox 7" "${PROXMOX7}" \
  "Proxmox 8" "${PROXMOX8}" \
  "Proxmox 9" "${PROXMOX9}"

# Single fetch, check all current and one upcoming Alma release
check_distro "https://mirror.rackspace.com/almalinux/"      present  \
  "Alma 8"    "${ALMA8}" \
  "Alma 9"    "${ALMA9}" \
  "Alma 10"   "${ALMA10}" \
  "Alma 11"   "${ALMA11}"

# Ubuntu ISO check - compare tracker to our local disk
#
# Ubuntu has a lot of in-flight updates so it's difficult to track each release
# so we scrape all active torrents from the official tracker and monitor for changes.

# $2 is not used here, but is needed for the while loop in fetch() to report errors
fetch "https://torrent.ubuntu.com/tracker_index" "Ubuntu" "notused"

# If we get a good response, scrape the torrent tracker page for a list of ISOs
if [[ $? -eq 0 ]]; then
    UBUNTU_TRACKER=$(grep -vE "beta|snapshot" <<< "${BODY}" | grep -oP '(?<=>)[^<]+\.iso(?=<)')
    if [[ -n "${UBUNTU_TRACKER}" ]]; then
        # Alert on tracker ISOs missing from our local disk
        while IFS= read -r iso; do
            # Transmission is aware of this ISO; nothing to do
            "${HAS_STATUS}" && grep -qF "${iso}" "${STATUS_FILE}" && continue
            if [[ -s "${ISO_DIR}/${iso}" ]]; then
                # ISO is on our local disk but transmission doesn't know about it
                "${HAS_STATUS}" && add_update "ORPHAN:${iso}"
            else
                # ISO is not on our local disk and not in transmission
                add_update "MISSING:${iso}"
            fi
        done <<< "${UBUNTU_TRACKER}"

        # Alert on stale Ubuntu ISOs on our local disk but removed from the tracker
        LOCAL_ISOS=("${ISO_DIR}"/ubuntu-*.iso)
        # No Ubuntu ISOs found on our local disk at all
        if [[ ! -s "${LOCAL_ISOS[0]}" ]]; then
            add_update "MISSING:ubuntu-*.iso"
        else
            for file in "${LOCAL_ISOS[@]}"; do
                iso=$(basename "${file}")
                # ISO is still on the tracker; nothing to do
                grep -qF "${iso}" <<< "${UBUNTU_TRACKER}" && continue
                # ISO is on our local disk but no longer on the tracker
                add_update "STALE:${iso}"
            done
        fi
    else
        add_update "MALFORMED:Ubuntu Tracker"
    fi
fi

# Report which torrents have updates, if any
if [[ -n "${UPDATES}" ]]; then
  echo "${UPDATES}"
  exit 1
fi

# We made it
exit 0
