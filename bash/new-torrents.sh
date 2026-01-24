#!/bin/bash
# Check for updates to torrents for our mirror

# Checks for release found in current directory
DEBIAN='13.3.0'
# Check for next release to show up as there is no current directory to look for
FEDORA='44'
# Alma only uses the first two
ALMA9='9.7'
ALMA10='10.1'
# Proxmox latest
PROXMOX='9.1-1'
# Ubuntu makes this hard so we scrape the torrent tracker and diff it
UBUNTU='/tmp/ubuntu-torrents.txt'

# Report what has updates if we find any
UPDATES=''

# cURL Options
COPTS='-s -m 5'

# Run the checks
curl ${COPTS} https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -q "${DEBIAN}" || UPDATES='Debian'
curl ${COPTS} https://mirror.rackspace.com/fedora/releases/ | grep -q "${FEDORA}" && UPDATES="${UPDATES} Fedora"
curl ${COPTS} https://mirror.rackspace.com/almalinux/9/isos/x86_64/ | grep -q "${ALMA9}" || UPDATES="${UPDATES} Alma 9"
curl ${COPTS} https://mirror.rackspace.com/almalinux/10/isos/x86_64/ | grep -q "${ALMA10}" || UPDATES="${UPDATES} Alma 10"
curl ${COPTS} https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso | grep -q "${PROXMOX}" || UPDATES="${UPDATES} Proxmox 9"

# Create temp file if missing
if [ ! -s "${UBUNTU}" ]; then
  curl ${COPTS} https://torrent.ubuntu.com/tracker_index | grep -v snapshot | grep iso | cut -d '>' -f 8 > ${UBUNTU} || exit 6
  exit 0
fi

# See what has changed in Ubuntu and clean-up if no changes
curl ${COPTS} https://torrent.ubuntu.com/tracker_index | grep -v beta | grep -v snapshot | grep iso | cut -d '>' -f 8 > ${UBUNTU}.new
diff -q ${UBUNTU} ${UBUNTU}.new > /dev/null || UPDATES="${UPDATES} Ubuntu"

# Report which torrents have updates, if any
if [ -n "${UPDATES}" ]; then
  echo ${UPDATES}
  exit 1
fi

# We made it
rm -f ${UBUNTU}.new
exit 0
