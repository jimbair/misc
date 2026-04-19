#!/bin/bash
# Check for updates to torrents for our mirror
# https://mirror.tsue.net/

# Checks for release found in current directory
DEBIAN='13.4.0'

# Check for next release to show up as there is no current directory to look for
FEDORA='44'

# Alma only uses the first two
ALMA9='9.7'
ALMA10='10.1'

# All the cool kids use arch. Check for current iso in /latest/
ARCH='2026.04.01'

# Proxmox
PROXMOX6='6.4-1'
PROXMOX7='7.4-1'
PROXMOX8='8.4-1'
PROXMOX9='9.1-1'

# CachyOS
CACHY='260308'

# Linux Mint
MINT='22.3'

# Ubuntu makes this hard so we scrape the torrent tracker and diff it
UBUNTU='/tmp/ubuntu-torrents.txt'

# Report what has updates if we find any
UPDATES=''

# Tracks consecutive curl failures per distro so transient outages
# are silently ignored but sustained ones get reported as NAME(DOWN).
FAIL_FILE='/tmp/new-torrents-failures.txt'
FAIL_THRESHOLD=3
touch "${FAIL_FILE}"

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

  # cURL with our options
  BODY=$(curl --silent --max-time 10 --fail-with-body "${URL}")

  if [ $? -ne 0 ]; then
    BODY=""
    # Track and report failure for every name associated with this URL
    while [ $# -ge 2 ]; do
      local NAME="${1}"
      shift 2
      COUNT=$(grep "^${NAME}=" "${FAIL_FILE}" | cut -d= -f2)
      COUNT=$(( ${COUNT:-0} + 1 ))
      if grep -q "^${NAME}=" "${FAIL_FILE}"; then
        sed -i "s/^${NAME}=.*/${NAME}=${COUNT}/" "${FAIL_FILE}"
      else
        echo "${NAME}=${COUNT}" >> "${FAIL_FILE}"
      fi
      if [ "${COUNT}" -ge "${FAIL_THRESHOLD}" ]; then
        UPDATES="${UPDATES} ${NAME}(DOWN)"
      fi
    done
    return 1
  fi

  # curl succeeded -- reset failure counters for all names
  while [ $# -ge 2 ]; do
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

  fetch "${URL}" "$@"
  if [ $? -ne 0 ]; then
    return
  fi

  while [ $# -ge 2 ]; do
    local NAME="${1}" PATTERN="${2}"
    shift 2
    if [ "${MATCH}" = "missing" ]; then
      echo "${BODY}" | grep -q "${PATTERN}" || UPDATES="${UPDATES} ${NAME}"
    elif [ "${MATCH}" = "present" ]; then
      echo "${BODY}" | grep -q "${PATTERN}" && UPDATES="${UPDATES} ${NAME}"
    else
      echo "ERROR: Unsuppoted check_distro match. Exiting."
      exit 1
    fi
  done
}

# Extracts ISO filenames from the Ubuntu tracker's HTML
parse_ubuntu_isos() {
    # Expects HTML body via stdin
    grep -vE "beta|snapshot" | grep -oP '(?<=>)[^<]+\.iso(?=<)'
}

########
# MAIN #
########

# Run the checks
check_distro "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/" missing  "Debian"    "${DEBIAN}"
check_distro "https://mirror.rackspace.com/fedora/releases/"              present  "Fedora"    "${FEDORA}"
check_distro "https://mirror.rackspace.com/almalinux/9/isos/x86_64/"      missing  "Alma 9"    "${ALMA9}"
check_distro "https://mirror.rackspace.com/almalinux/10/isos/x86_64/"     missing  "Alma 10"   "${ALMA10}"
check_distro "https://mirror.rackspace.com/archlinux/iso/latest/"         missing  "Arch"      "${ARCH}"
check_distro "https://cachyos.org/download/"                              missing  "CachyOS"   "${CACHY}"
check_distro "https://linuxmint.com/download.php"                         missing  "LinuxMint" "${MINT}"

# Single fetch, four version checks
check_distro "https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso" missing \
  "Proxmox 6" "${PROXMOX6}" \
  "Proxmox 7" "${PROXMOX7}" \
  "Proxmox 8" "${PROXMOX8}" \
  "Proxmox 9" "${PROXMOX9}"

# Bootstrap baseline file if missing, otherwise diff for changes
if [ ! -s "${UBUNTU}" ]; then
  # Ubuntu needs to pass both the name and fake pattern for site down detection to work
  fetch "https://torrent.ubuntu.com/tracker_index" "Ubuntu" "notused"
  if [ $? -ne 0 ]; then
    echo "Unable to reach Ubuntu tracker on first run. Exiting."
    exit 1
  fi
  
  echo "${BODY}" | parse_ubuntu_isos > "${UBUNTU}"
  if [ ! -s "${UBUNTU}" ]; then
    echo "Unable to create initial Ubuntu temp file. Exiting."
    exit 1
  fi
else
  # The ubuntu tracker likes to go offline quite a bit sadly
  # If it's down, fetch handles the failure tracking for us.
  fetch "https://torrent.ubuntu.com/tracker_index"  "Ubuntu" "notused"
  if [ $? -eq 0 ]; then
    echo "${BODY}" | parse_ubuntu_isos > "${UBUNTU}.new"
    # If there are updates, leave the .new file in place (and allow updates, in case an update is rolled back)
    # for manual diffing to see what has changed since the previous stable state file.
    if [ -s "${UBUNTU}.new" ]; then
      diff -q "${UBUNTU}" "${UBUNTU}.new" > /dev/null || UPDATES="${UPDATES} Ubuntu"
    fi
  fi
fi

# Report which torrents have updates, if any
if [ -n "${UPDATES}" ]; then
  echo "${UPDATES# }"
  exit 1
fi

# We made it
rm -f "${UBUNTU}.new"
exit 0
