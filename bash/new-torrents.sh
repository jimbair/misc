#!/bin/bash
# Check for updates to torrents for our mirror
# https://mirror.tsue.net/
#
# This script runs once an hour via cron and raises alerts via healthchecks.io
# We send the output as a POST to /fail in the event of a non-zero exit.

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
  grep -qFx "${NEW}" <<< "${UPDATES}" && return

  if [[ -z "${UPDATES}" ]]; then
    UPDATES="${NEW}"
  else
    UPDATES="${UPDATES}"$'\n'"${NEW}"
  fi
}

# Fetch a URL, storing the response in the global BODY variable.
# Tracks consecutive failures per name and alerts once FAIL_THRESHOLD is reached.
# Resets failure counters on success.
#
# Usage: fetch URL NAME
#   URL  - the URL to fetch
#   NAME - name used to track failure counts in FAIL_FILE
fetch() {
  local URL="${1}" NAME="${2}"
  local COUNT

  # Extract the domain for use in down-alerts
  DOMAIN=$(awk -F[/:] '{print $4}' <<< "${URL}")

  # Fetch the URL; result is available globally as BODY
  BODY=$(curl --silent --max-time 10 --compressed --fail-with-body "${URL}")

  # On failure, increment the failure counter and alert once FAIL_THRESHOLD is reached
  if [[ $? -ne 0 ]]; then
    BODY=""
    touch "${FAIL_FILE}"
    COUNT=$(grep -F "${NAME}=" "${FAIL_FILE}" | cut -d= -f2)
    COUNT=$(( ${COUNT:-0} + 1 ))
    if grep -qF "${NAME}=" "${FAIL_FILE}"; then
      grep -vF "${NAME}=" "${FAIL_FILE}" > "${FAIL_FILE}.tmp"
      mv "${FAIL_FILE}.tmp" "${FAIL_FILE}"
    fi
    echo "${NAME}=${COUNT}" >> "${FAIL_FILE}"
    [[ "${COUNT}" -ge "${FAIL_THRESHOLD}" ]] && add_update "${DOMAIN}"
    return 1
  fi

  # On success, clear the failure counter if one exists for this name
  [[ ! -s "${FAIL_FILE}" ]] && return 0
  if grep -qF "${NAME}=" "${FAIL_FILE}"; then
    grep -vF "${NAME}=" "${FAIL_FILE}" > "${FAIL_FILE}.tmp"
    mv "${FAIL_FILE}.tmp" "${FAIL_FILE}"
  fi
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

# Check a flat ISO file against transmission status and local disk.
#
# Usage: check_iso ISO [NEW_ALERT]
#   ISO       - ISO filename to check (e.g. debian-13.5.0-amd64-netinst.iso)
#   NEW_ALERT - optional alert name override for the missing case; defaults to
#               NEW:ISO. Used when the caller wants a version-level alert name
#               rather than a per-ISO name (e.g. NEW:Arch-2026.05.01).
check_iso() {
  local ISO="${1}" NEW_ALERT="${2:-NEW:${1}}"

  # Transmission knows about this ISO; nothing to do
  grep -qF "${ISO}" "${STATUS_FILE}" && return 0

  # ISO is on disk but transmission has no record of it
  if [[ -s "${ISO_DIR}/${ISO}" ]]; then
    add_update "ORPHAN:${ISO}"
  # ISO is not on disk and not known to transmission
  else
    add_update "${NEW_ALERT}"
  fi
}

# Check a torrent directory against transmission status and local disk.
#
# Usage: check_dir DIR
#   DIR - directory name to check (e.g. Fedora-Workstation-Live-x86_64-44)
check_dir() {
  local DIR="${1}"

  # Transmission knows about this directory; nothing to do
  grep -qF "${DIR}" "${STATUS_FILE}" && return 0

  # Directory is on disk but transmission has no record of it
  if [[ -d "${ISO_DIR}/${DIR}" ]]; then
    add_update "ORPHAN:${DIR}"
  # Directory is not on disk and not known to transmission
  else
    add_update "NEW:${DIR}"
  fi
}

# Fetch and process the Linux Mint stable file index, comparing active ISOs
# against local disk and transmission status.
#
# pub.linuxmint.io/stable/ is a plain directory index listing all historical
# release version directories. The latest version is determined by taking the
# highest version directory via sort -V. The version directory itself lists the
# current ISOs directly as flat files, matching the names transmission uses.
#
# This approach requires two fetches but is more reliable than scraping the
# main download page or per-edition subpages, which load content dynamically
# and have been observed to 404 for some editions (e.g. the EDGE ISO). If EDGE
# or any other variant appears in the version directory it will be picked up
# automatically without any script changes.
#
# Per-ISO alerts:
#   NEW:ISO                  - index ISO absent from disk and unknown to transmission
#   ORPHAN:ISO               - index ISO present on disk but unknown to transmission
#   STALE:ISO                - local linuxmint-*.iso not present in current version directory
#   MISSING:linuxmint-*.iso  - no Linux Mint ISOs found on our disk at all
#   MALFORMED:Linux-Mint     - stable index returned no version directories
#   MALFORMED:Linux-Mint-VER - version directory returned no ISOs

check_mint() {
  fetch "https://pub.linuxmint.io/stable/" "Linux-Mint" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract the latest version directory from the stable index
  local CURRENT_VERSION
  CURRENT_VERSION=$(grep -oP 'href="\K[0-9]+\.[0-9]+(?=/)' <<< "${BODY}" | sort -V | tail -1)

  # I'm sure this will break on us one day
  if [[ -z "${CURRENT_VERSION}" ]]; then
    add_update "MALFORMED:Linux-Mint"
    return 1
  fi

  # Fetch the version directory to get the current ISO listing
  fetch "https://pub.linuxmint.io/stable/${CURRENT_VERSION}/" "Linux-Mint-VER" || return 1
  body_ok "${DOMAIN}" || return 1

  local MINT_TRACKER
  MINT_TRACKER=$(grep -oP 'href="\Klinuxmint-[^"]+\.iso(?=")' <<< "${BODY}" | sort)

  # I'm sure this will break on us one day
  if [[ -z "${MINT_TRACKER}" ]]; then
    add_update "MALFORMED:Linux-Mint-${CURRENT_VERSION}"
    return 1
  fi

  # Alert on index ISOs missing from local disk or unknown to transmission
  while IFS= read -r ISO; do
    check_iso "${ISO}"
  done <<< "${MINT_TRACKER}"

  # Alert on local linuxmint-*.iso files no longer present in the current version directory
  local LOCAL_ISOS
  LOCAL_ISOS=("${ISO_DIR}"/linuxmint-*.iso)

  # The glob matched nothing; no Linux Mint ISOs on disk at all
  if [[ ! -s "${LOCAL_ISOS[0]}" ]]; then
    add_update "MISSING:linuxmint-*.iso"
    return 0
  fi

  for FILE in "${LOCAL_ISOS[@]}"; do
    local ISO
    ISO=$(basename "${FILE}")

    # Still present in the current version directory; nothing to do
    grep -qF "${ISO}" <<< "${MINT_TRACKER}" && continue

    # Local ISO is no longer listed in the current version directory
    add_update "STALE:${ISO}"
  done
}

# Fetch and process the CachyOS download page, comparing the current release
# against local disk and transmission status.
#
# cachyos.org/download/ embeds torrent metadata in HTML-entity-encoded JSON
# props on astro-island components, one per edition. The torrent_url field
# contains the full URL to the .torrent file, from which the base ISO name is
# extracted and .iso appended since CachyOS torrent filenames do not include
# the .iso extension.
#
# CachyOS is a rolling release like Arch; all editions share a single release
# date (e.g. 260426) and older ISOs serve no functional purpose. Only the
# current release is valid; any local cachyos-*.iso not matching the current
# release date is flagged as stale.
#
# Alerts:
#   NEW:CachyOS-YYMMDD          - current release not present on local disk
#   ORPHAN:cachyos-EDITION.iso  - current ISO on disk but unknown to transmission
#   STALE:cachyos-OLD.iso       - local ISO superseded by the current release
#   MALFORMED:cachyos.org       - page returned no torrent URLs
check_cachy() {
  fetch "https://cachyos.org/download/" "CachyOS" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract all current ISO names from the HTML-entity-encoded torrent_url fields.
  # CachyOS torrent filenames omit the .iso extension so we append it after extraction.
  local CACHY_TRACKER
  CACHY_TRACKER=$(grep -oP 'torrent_url&quot;:\[0,&quot;[^&]+/\Kcachyos-[^&]+(?=\.torrent&quot;)' \
    <<< "${BODY}" | sed 's/$/.iso/' | sort)

  # I'm sure this will break on us one day
  if [[ -z "${CACHY_TRACKER}" ]]; then
    add_update "MALFORMED:cachyos.org"
    return 1
  fi

  # Extract the current release date shared across all editions (e.g. 260426).
  # All editions on the page are built from the same release so we take the
  # first match; if editions ever diverge this will need revisiting.
  local CURRENT_RELEASE
  CURRENT_RELEASE=$(grep -oP 'cachyos-[^-]+-linux-\K\d+(?=\.iso)' <<< "${CACHY_TRACKER}" \
    | sort -u | tail -1)

  # Check each current edition ISO against transmission status and local disk,
  # using a version-level alert name to match the Arch single-release model
  while IFS= read -r ISO; do
    check_iso "${ISO}" "NEW:CachyOS-${CURRENT_RELEASE}"
  done <<< "${CACHY_TRACKER}"

  # Alert on any local cachyos-*.iso files that are no longer the current release.
  # Runs unconditionally so stale ISOs are caught even when the current ones
  # are already known to transmission.
  for FILE in "${ISO_DIR}"/cachyos-*.iso; do
    [[ -s "${FILE}" ]] || continue
    local ISO
    ISO=$(basename "${FILE}")

    # Still in the current release listing; nothing to do
    grep -qF "${ISO}" <<< "${CACHY_TRACKER}" && continue

    # Local ISO is superseded by the current release
    add_update "STALE:${ISO}"
  done
}

# Fetch and process the Arch Linux download page, comparing the current release
# against torrent(s) on our local disk.
#
# archlinux.org/download/ lists the current release date as a structured field,
# making it straightforward to extract without scraping multiple pages or tracking
# version numbers manually. ISOs land as flat files in ISO_DIR, named
# archlinux-YYYY.MM.DD-x86_64.iso, matching the transmission download name.
#
# Arch publishes one new torrent monthly. However, older ISOs are superseded
# by each monthly release and serve no functional purpose as pacman will roll
# any installed system to current regardless of which ISO was used.
#
# Alerts:
#   NEW:Arch-YYYY.MM.DD              - current release not present on local disk
#   ORPHAN:archlinux-YYYY-x86_64.iso - current ISO on disk but unknown to transmission
#   STALE:archlinux-OLD-x86_64.iso   - local ISO superseded by a newer release
check_arch() {
  fetch "https://archlinux.org/download/" "Arch" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract the current release date from the structured field on the download page
  local CURRENT_RELEASE
  CURRENT_RELEASE=$(grep -oP '(?<=Current Release:</strong> )\d{4}\.\d{2}\.\d{2}' <<< "${BODY}")

  # I'm sure this will break on us one day
  if [[ -z "${CURRENT_RELEASE}" ]]; then
    add_update "MALFORMED:archlinux.org"
    return 1
  fi

  local CURRENT_ISO="archlinux-${CURRENT_RELEASE}-x86_64.iso"

  # Check the current release ISO against transmission status and local disk,
  # using a version-level alert name rather than per-ISO to match Arch's
  # single-ISO-per-release model
  check_iso "${CURRENT_ISO}" "NEW:Arch-${CURRENT_RELEASE}"

  # Alert on any local Arch ISOs that are no longer the current release.
  # Runs unconditionally so stale ISOs are caught even when the current one
  # is already known to transmission.
  for FILE in "${ISO_DIR}"/archlinux-*.iso; do
    [[ -s "${FILE}" ]] || continue
    local ISO
    ISO=$(basename "${FILE}")

    # Skip the current release; we only want to flag superseded ISOs
    [[ "${ISO}" == "${CURRENT_ISO}" ]] && continue

    # Local ISO is no longer the current release
    add_update "STALE:${ISO}"
  done
}

# Walk the tracker torrents for a single Fedora version and compare against
# local disk and transmission status. Called only for versions present on the
# tracker where at least one local directory already exists for that version,
# indicating the version is actively being mirrored.
#
# Usage: check_fedora_version VER VER_TORRENTS
#   VER          - the Fedora version number (e.g. 44)
#   VER_TORRENTS - newline-separated list of .torrent filenames for VER
#
# Alerts:
#   NEW:DIR    - torrent directory absent from disk and unknown to transmission
#   ORPHAN:DIR - torrent directory present on disk but unknown to transmission
#   STALE:DIR  - torrent directory present on disk but removed from the tracker
check_fedora_version() {
  local VER="${1}" VER_TORRENTS="${2}"

  # Check each tracker torrent against transmission status and local disk
  while IFS= read -r TORRENT; do
    # Transmission names downloads after the torrent filename minus the .torrent suffix
    local DIR="${TORRENT%.torrent}"
    check_dir "${DIR}"
  done <<< "${VER_TORRENTS}"

  # Check for local directories for this version no longer listed on the tracker.
  # The glob is scoped to -${VER}/ to avoid matching other versions.
  local LOCAL_FEDORA
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

# Fetch and process the Fedora torrent JSON, comparing it against local disk
# and transmission status.
#
# Fedora publishes a JSON of all active torrents at torrent.fedoraproject.org,
# covering all releases in a single response. Each torrent unpacks into a
# subdirectory named after the torrent file minus the .torrent suffix, so
# directory presence is used instead of ISO filename matching.
#
# The active version set is derived from the union of what the tracker publishes
# and what exists on local disk, so no script changes are needed when versions
# are added or removed upstream.
#
# Version-level alerts (one alert per version, not one per torrent):
#   NEW:Fedora-VER     - version appeared in JSON but no local directories exist yet
#   DROPPED:Fedora-VER - local directories exist for a version absent from the JSON
#
# Per-torrent alerts (only once at least one local directory exists for a version):
#   NEW:DIR    - torrent directory absent from disk and unknown to transmission
#   ORPHAN:DIR - torrent directory present on disk but unknown to transmission
#   STALE:DIR  - torrent directory present on disk but removed from the tracker
check_fedora() {
  fetch "https://torrent.fedoraproject.org/torrents.json" "Fedora" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract the sorted list of release version names currently on the tracker
  local FEDORA_TRACKER_VERSIONS
  FEDORA_TRACKER_VERSIONS=$(jq -r '.[].name' <<< "${BODY}" | sort -V)

  # I'm sure this will break on us one day
  if [[ -z "${FEDORA_TRACKER_VERSIONS}" ]]; then
    add_update "MALFORMED:Fedora-Tracker"
    return 1
  fi

  # Extract versions present in local Fedora directories, if any exist.
  # This forms the local half of the version union used for DROPPED detection.
  local FEDORA_LOCAL_VERSIONS=()
  for DIR in "${ISO_DIR}"/Fedora-*-*/; do
    [[ -d "${DIR}" ]] || continue
    # Extract the version suffix (e.g. Fedora-Workstation-Live-x86_64-44 -> 44)
    local VER="${DIR%/}"
    VER="${VER##*-}"
    # Add to local versions array if not already present
    [[ " ${FEDORA_LOCAL_VERSIONS[*]} " == *" ${VER} "* ]] && continue
    FEDORA_LOCAL_VERSIONS+=("${VER}")
  done

  while IFS= read -r VER; do
    local LOCAL_VER_DIRS
    LOCAL_VER_DIRS=("${ISO_DIR}"/Fedora-*-"${VER}"/)

    # Version is on the tracker but no local directories exist yet; alert at
    # the version level to avoid a wall of per-torrent alerts on release day
    if [[ ! -d "${LOCAL_VER_DIRS[0]}" ]]; then
      add_update "NEW:Fedora-${VER}"
      continue
    fi

    # At least one local directory exists for this version; check individual torrents
    local FEDORA_VER_TORRENTS
    FEDORA_VER_TORRENTS=$(jq -r --arg V "${VER}" \
      '.[] | select(.name == $V) | .torrents[].torrent' <<< "${BODY}" | sort)
    check_fedora_version "${VER}" "${FEDORA_VER_TORRENTS}"
  done <<< "${FEDORA_TRACKER_VERSIONS}"

  # Alert once for each local version absent from the tracker (dropped release).
  # Fires on every run until the local directories are removed.
  for VER in "${FEDORA_LOCAL_VERSIONS[@]}"; do
    # Version is still on the tracker; nothing to do
    grep -qw "${VER}" <<< "${FEDORA_TRACKER_VERSIONS}" && continue

    # Local version is no longer listed on the tracker
    add_update "DROPPED:Fedora-${VER}"
  done
}

# Compare the current AlmaLinux point release for a major version against local
# disk and transmission status. Called only for majors confirmed present on both
# isos.html and in local directories.
#
# A new point release under a tracked major (e.g. 10.2 replacing 10.1) raises a
# single NEW:AlmaLinux-10.2 alert rather than one per arch. Per-arch NEW: and
# ORPHAN: checks fire once at least one local directory exists for the current
# point release. STALE: fires for any local directory whose point release is no
# longer the current one listed on isos.html.
#
# Usage: check_alma_version MAJOR CURRENT_VERSION ARCHES
#   MAJOR           - the AlmaLinux major version number (e.g. 10)
#   CURRENT_VERSION - the current full point release from isos.html (e.g. 10.1)
#   ARCHES          - newline-separated list of arches for this version
#
# Alerts:
#   NEW:AlmaLinux-VER         - current point release has no local directories yet
#   NEW:AlmaLinux-VER-ARCH    - expected arch directory missing from disk and transmission
#   ORPHAN:AlmaLinux-VER-ARCH - directory present on disk but unknown to transmission
#   STALE:AlmaLinux-VER-ARCH  - local directory superseded by a newer point release
check_alma_version() {
  local MAJOR="${1}" CURRENT_VERSION="${2}" ARCHES="${3}"

  # Check whether the current point release is present locally. If any arch
  # directory exists for the current version, the release is considered known.
  local LOCAL_CURRENT
  LOCAL_CURRENT=("${ISO_DIR}"/AlmaLinux-"${CURRENT_VERSION}"-*/)

  # Current point release has no local directories yet; alert at the version
  # level to avoid a wall of per-arch alerts and skip per-arch checks since
  # there is nothing to compare against until we have at least one directory
  if [[ ! -d "${LOCAL_CURRENT[0]}" ]]; then
    add_update "NEW:AlmaLinux-${CURRENT_VERSION}"
  else
    # At least one local directory exists for this version; check each arch
    # individually to catch any new arches that may have appeared upstream
    while IFS= read -r ARCH; do
      local DIR="AlmaLinux-${CURRENT_VERSION}-${ARCH}"
      check_dir "${DIR}"
    done <<< "${ARCHES}"
  fi

  # Alert on local directories for this major version whose point release
  # is no longer current on isos.html (i.e. superseded by a newer point release).
  local LOCAL_ALMA
  LOCAL_ALMA=("${ISO_DIR}"/AlmaLinux-"${MAJOR}".*-*/)
  for DIR in "${LOCAL_ALMA[@]}"; do
    [[ -d "${DIR}" ]] || continue
    DIR=$(basename "${DIR%/}")
    # Extract the version portion (e.g. AlmaLinux-10.0-x86_64 -> 10.0)
    local VER="${DIR#AlmaLinux-}"
    VER="${VER%-*}"

    # Still the current point release; nothing to do
    [[ "${VER}" == "${CURRENT_VERSION}" ]] && continue

    # Local directory is superseded by a newer point release
    add_update "STALE:${DIR}"
  done
}

# Fetch and process the AlmaLinux isos.html page, comparing it against local
# disk and transmission status.
#
# isos.html lists the current point release per major version per arch. Sadly,
# AlmaLinux doesn't have a torrent-specific landing page like Ubuntu or Fedora.
# The older torrents are never disabled from the tracker like Fedora, but since
# Alma always rolls, there's no benefit to keeping the older ISOs around.
#
# Version-level alerts (one alert per event, not one per arch):
#   NEW:AlmaLinux-MAJOR       - a new major appeared on isos.html with no local directories
#   NEW:AlmaLinux-VER         - a new point release exists on isos.html but not locally
#   DROPPED:AlmaLinux-MAJ     - local directories exist for a major absent from isos.html
#
# Per version+arch alerts (only when at least one local directory exists for the version):
#   NEW:AlmaLinux-VER-ARCH    - expected directory absent from disk and transmission
#   ORPHAN:AlmaLinux-VER-ARCH - directory present on disk but unknown to transmission
#   STALE:AlmaLinux-VER-ARCH  - local directory superseded by a newer point release
check_alma() {
  fetch "https://mirrors.almalinux.org/isos.html" "AlmaLinux" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract all unique version+arch pairs from isos.html links of the form
  # /isos/ARCH/VERSION.html, producing lines of "VERSION ARCH" sorted by version
  local ALMA_PAIRS
  ALMA_PAIRS=$(grep -oP '/isos/\K[^/]+/[0-9]+\.[0-9]+(?=\.html)' <<< "${BODY}" \
    | awk -F/ '{print $2, $1}' | sort -V | uniq)

  # I'm sure this will break on us one day
  if [[ -z "${ALMA_PAIRS}" ]]; then
    add_update "MALFORMED:AlmaLinux-isos.html"
    return 1
  fi

  # Extract the unique set of major versions currently listed on isos.html
  local ALMA_TRACKER_MAJORS
  ALMA_TRACKER_MAJORS=$(awk '{print $1}' <<< "${ALMA_PAIRS}" \
    | cut -d. -f1 | sort -uV)

  # Extract the unique set of major versions present in local directories, if any.
  # This forms the local half of the major version union used for DROPPED detection.
  local ALMA_LOCAL_MAJORS=()
  for DIR in "${ISO_DIR}"/AlmaLinux-*.*-*/; do
    [[ -d "${DIR}" ]] || continue
    # Extract the major version (e.g. AlmaLinux-10.1-x86_64 -> 10)
    local MAJ="${DIR%/}"
    MAJ="${MAJ##*AlmaLinux-}"
    MAJ="${MAJ%%.*}"
    # Add to local majors array if not already present
    [[ " ${ALMA_LOCAL_MAJORS[*]} " == *" ${MAJ} "* ]] && continue
    ALMA_LOCAL_MAJORS+=("${MAJ}")
  done

  while IFS= read -r MAJOR; do
    local LOCAL_MAJOR_DIRS
    LOCAL_MAJOR_DIRS=("${ISO_DIR}"/AlmaLinux-"${MAJOR}".*-*/)

    # Major is on isos.html but has no local directories yet; alert at the
    # major level and skip point release checks until we have something local
    if [[ ! -d "${LOCAL_MAJOR_DIRS[0]}" ]]; then
      add_update "NEW:AlmaLinux-${MAJOR}"
      continue
    fi

    # Major is present locally; extract the current point release and arches
    # from isos.html and hand off to check_alma_version for validation
    local CURRENT_VERSION
    CURRENT_VERSION=$(awk '{print $1}' <<< "${ALMA_PAIRS}" \
      | grep "^${MAJOR}\." | sort -V | tail -1)

    local CURRENT_ARCHES
    CURRENT_ARCHES=$(grep "^${CURRENT_VERSION} " <<< "${ALMA_PAIRS}" \
      | awk '{print $2}' | sort)

    check_alma_version "${MAJOR}" "${CURRENT_VERSION}" "${CURRENT_ARCHES}"
  done <<< "${ALMA_TRACKER_MAJORS}"

  # Alert once for each local major absent from isos.html (dropped/EOL major).
  # Fires on every run until the local directories are removed.
  for MAJ in "${ALMA_LOCAL_MAJORS[@]}"; do
    # Major is still listed on isos.html; nothing to do
    grep -qw "${MAJ}" <<< "${ALMA_TRACKER_MAJORS}" && continue

    # Local major is no longer listed on isos.html
    add_update "DROPPED:AlmaLinux-${MAJ}"
  done
}

# Fetch and process the Ubuntu torrent tracker page, comparing it against local
# disk and transmission status.
#
# Ubuntu releases ISOs frequently and names them inconsistently across point
# releases, so we scrape all active non-beta, non-snapshot ISO names from the
# official tracker and compare against local disk rather than tracking versions.
#
# Per-ISO alerts:
#   NEW:ISO              - tracker ISO absent from disk and unknown to transmission
#   ORPHAN:ISO           - tracker ISO present on disk but unknown to transmission
#   STALE:ISO            - local ubuntu-*.iso no longer listed on the tracker
#   MISSING:ubuntu-*.iso - no Ubuntu ISOs found on our disk at all
check_ubuntu() {
  fetch "https://torrent.ubuntu.com/tracker_index" "Ubuntu" || return 1
  body_ok "${DOMAIN}" || return 1

  local UBUNTU_TRACKER
  UBUNTU_TRACKER=$(grep -vE "beta|snapshot" <<< "${BODY}" | grep -oP '(?<=>)[^<]+\.iso(?=<)')

  # I'm sure this will break on us one day
  if [[ -z "${UBUNTU_TRACKER}" ]]; then
    add_update "MALFORMED:Ubuntu-Tracker"
    return 1
  fi

  # Alert on tracker ISOs missing from local disk or unknown to transmission
  while IFS= read -r ISO; do
    check_iso "${ISO}"
  done <<< "${UBUNTU_TRACKER}"

  # Alert on local ubuntu-*.iso files no longer listed on the tracker
  local LOCAL_ISOS
  LOCAL_ISOS=("${ISO_DIR}"/ubuntu-*.iso)

  # The glob matched nothing; no Ubuntu ISOs on disk at all
  if [[ ! -s "${LOCAL_ISOS[0]}" ]]; then
    add_update "MISSING:ubuntu-*.iso"
    return 0
  fi

  for FILE in "${LOCAL_ISOS[@]}"; do
    local ISO
    ISO=$(basename "${FILE}")

    # Still on the tracker; nothing to do
    grep -qF "${ISO}" <<< "${UBUNTU_TRACKER}" && continue

    # Local ISO is no longer listed on the tracker
    add_update "STALE:${ISO}"
  done
}

# Fetch and process the Proxmox VE downloads page, comparing it against local
# disk and transmission status.
#
# The parent downloads page lists only actively supported ISO versions, while
# the /iso subpage also includes EOL releases. We use the parent page so that
# EOL versions are automatically detected as stale once Proxmox removes them.
#
# Version strings are extracted via the MAJOR.MINOR-PATCH pattern (e.g. 9.1-1)
# which uniquely identifies ISO releases on the page. Local ISOs follow the
# naming convention proxmox-ve_X.Y-Z.iso.
#
# Alerts:
#   NEW:Proxmox-X.Y-Z           - version on page but no local ISO exists
#   ORPHAN:proxmox-ve_X.Y-Z.iso - ISO on disk but unknown to transmission
#   STALE:proxmox-ve_X.Y-Z.iso  - local ISO superseded by a newer point release
#   DROPPED:Proxmox-MAJOR       - local ISOs exist for a major absent from the page
check_proxmox() {
  fetch "https://www.proxmox.com/en/downloads/proxmox-virtual-environment" "Proxmox" || return 1
  body_ok "${DOMAIN}" || return 1

  # Extract unique ISO version strings (MAJOR.MINOR-PATCH format)
  local PROXMOX_VERSIONS
  PROXMOX_VERSIONS=$(grep -oP '\d+\.\d+-\d+' <<< "${BODY}" | sort -uV)

  # I'm sure this will break on us one day
  if [[ -z "${PROXMOX_VERSIONS}" ]]; then
    add_update "MALFORMED:Proxmox-Downloads"
    return 1
  fi

  # Extract the set of major versions listed on the page
  local PROXMOX_PAGE_MAJORS
  PROXMOX_PAGE_MAJORS=$(cut -d. -f1 <<< "${PROXMOX_VERSIONS}" | sort -uV)

  # For each version on the page, check local disk and transmission status
  while IFS= read -r VER; do
    local ISO="proxmox-ve_${VER}.iso"
    check_iso "${ISO}" "NEW:Proxmox-${VER}"
  done <<< "${PROXMOX_VERSIONS}"

  # Check local Proxmox ISOs against the page versions.
  # Alert STALE for ISOs whose major is still listed but point release is outdated,
  # and DROPPED for ISOs whose major version is entirely absent from the page.
  for FILE in "${ISO_DIR}"/proxmox-ve_*.iso; do
    [[ -s "${FILE}" ]] || continue
    local ISO
    ISO=$(basename "${FILE}")
    # Extract version from filename (proxmox-ve_9.1-1.iso -> 9.1-1)
    local VER="${ISO#proxmox-ve_}"
    VER="${VER%.iso}"

    # Still listed on the page; nothing to do
    grep -qF "${VER}" <<< "${PROXMOX_VERSIONS}" && continue

    # Determine if this is a stale point release or a dropped major
    local MAJOR="${VER%%.*}"
    if grep -qF "${MAJOR}" <<< "${PROXMOX_PAGE_MAJORS}"; then
      # Major is still active but this point release has been superseded
      add_update "STALE:${ISO}"
    else
      # Major version is entirely absent from the downloads page
      add_update "DROPPED:Proxmox-${MAJOR}"
    fi
  done
}

# Fetch and process the Debian torrent list via rsync --list-only, comparing
# it against local disk and transmission status.
#
# rsync://cdimage.debian.org/debian-cd/ contains only the current stable point
# release; older point releases are moved to a separate archive. This means the
# rsync listing is always ~42 torrents for the current release across all arches
# and flavors (standard installer + live), with no stale cross-version problem.
#
# Per-ISO alerts:
#   NEW:ISO                  - rsync ISO absent from disk and unknown to transmission
#   ORPHAN:ISO               - rsync ISO present on disk but unknown to transmission
#   STALE:ISO                - local debian-*.iso no longer listed in rsync output
#   MISSING:debian-*.iso     - no Debian ISOs found on our disk at all
#   MALFORMED:Debian-Tracker - rsync ran but returned no .torrent filenames
check_debian() {
  local RSYNC_OUTPUT
  RSYNC_OUTPUT=$(rsync --list-only --no-motd -r \
    --include='*/' \
    --include='*.torrent' \
    --exclude='*' \
    rsync://cdimage.debian.org/debian-cd/ 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    touch "${FAIL_FILE}"
    local COUNT
    COUNT=$(grep -F "Debian=" "${FAIL_FILE}" | cut -d= -f2)
    COUNT=$(( ${COUNT:-0} + 1 ))
    if grep -qF "Debian=" "${FAIL_FILE}"; then
      grep -vF "Debian=" "${FAIL_FILE}" > "${FAIL_FILE}.tmp"
      mv "${FAIL_FILE}.tmp" "${FAIL_FILE}"
    fi
    echo "Debian=${COUNT}" >> "${FAIL_FILE}"
    [[ "${COUNT}" -ge "${FAIL_THRESHOLD}" ]] && add_update "cdimage.debian.org"
    return 1
  fi

  # Clear any stored failure counter on success
  if [[ -s "${FAIL_FILE}" ]] && grep -qF "Debian=" "${FAIL_FILE}"; then
    grep -vF "Debian=" "${FAIL_FILE}" > "${FAIL_FILE}.tmp"
    mv "${FAIL_FILE}.tmp" "${FAIL_FILE}"
  fi

  # Extract ISO filenames: strip leading directory path and .torrent suffix
  # to get the name transmission uses for the completed download
  local DEBIAN_TRACKER
  DEBIAN_TRACKER=$(awk '/\.torrent$/ {print $NF}' <<< "${RSYNC_OUTPUT}" \
    | xargs -I{} basename {} .torrent | sort)

  # I'm sure this will break on us one day
  if [[ -z "${DEBIAN_TRACKER}" ]]; then
    add_update "MALFORMED:Debian-Tracker"
    return 1
  fi

  # Alert on tracker ISOs missing from local disk or unknown to transmission
  while IFS= read -r ISO; do
    check_iso "${ISO}"
  done <<< "${DEBIAN_TRACKER}"

  # Alert on local debian-*.iso files no longer listed in the rsync output
  local LOCAL_ISOS
  LOCAL_ISOS=("${ISO_DIR}"/debian-*.iso)

  # The glob matched nothing; no Debian ISOs on disk at all
  if [[ ! -s "${LOCAL_ISOS[0]}" ]]; then
    add_update "MISSING:debian-*.iso"
    return 0
  fi

  for FILE in "${LOCAL_ISOS[@]}"; do
    local ISO
    ISO=$(basename "${FILE}")

    # Still in the rsync listing; nothing to do
    grep -qF "${ISO}" <<< "${DEBIAN_TRACKER}" && continue

    # Local ISO is no longer listed in the rsync output
    add_update "STALE:${ISO}"
  done
}

########
# MAIN #
########

# Bail early if the download directory is missing
if [[ ! -d "${ISO_DIR}" ]]; then
  echo "ERROR: transmission download directory ${ISO_DIR} is missing. Exiting."
  exit 1
# Bail early if jq is missing
elif ! jq --help &> /dev/null; then
  echo "ERROR: Please install jq to proceed. Exiting."
  exit 1
# Bail early if rsync is missing
elif ! rsync --version &> /dev/null; then
  echo "ERROR: Please install rsync to proceed. Exiting."
  exit 1
fi

# Require a valid status.txt to proceed; without it we cannot detect orphaned
# torrents and the mirror state cannot be fully verified
if [[ ! -s "${STATUS_FILE}" ]]; then
  echo "ERROR: status.txt is missing or empty at ${STATUS_FILE}. Exiting."
  exit 1
elif ! grep -q "^Sum:" "${STATUS_FILE}"; then
  echo "ERROR: status.txt appears malformed at ${STATUS_FILE}. Exiting."
  exit 1
fi

# Enable bash trace output for interactive debugging
[[ "${1}" == "--debug" ]] && set -x

# Dynamic checks for all monitored distributions
check_cachy
check_mint
check_arch
check_fedora
check_alma
check_ubuntu
check_proxmox
check_debian

# Report all accumulated alerts and exit non-zero so healthchecks.io fires
if [[ -n "${UPDATES}" ]]; then
  echo "${UPDATES}"
  exit 1
fi

# All checks passed
exit 0
