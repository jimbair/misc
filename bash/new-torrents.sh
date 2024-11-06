#!/bin/bash
# Check for updates to torrents for our mirror

# Checks for release found in current directory
DEBIAN='12.6.0'
# Check for next release to show up as there is no current directory to look for
FEDORA='42'
# Alma only uses the first two
ALMA='8.10'
# Ubuntu makes this hard so we scrape the torrent tracker and diff it
UBUNTU='/tmp/ubuntu-torrents.txt'

# Report what has updates if we find any
UPDATES=''

# Run the checks
curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -q "${DEBIAN}" || UPDATES='Debian'
curl -s https://mirror.rackspace.com/fedora/releases/ | grep -q "${FEDORA}" && UPDATES="${UPDATES} Fedora"
curl -s https://mirror.rackspace.com/almalinux/8/isos/x86_64/ | grep -q "${ALMA}" || UPDATES="${UPDATES} Alma 8"

# Create temp file if missing
if [ ! -s "${UBUNTU}" ]; then
  curl -s https://torrent.ubuntu.com/tracker_index | grep iso | cut -d '>' -f 8 > ${UBUNTU} || exit 6
  exit 0
fi

# See what has changed in Ubuntu and clean-up if no changes
curl -s https://torrent.ubuntu.com/tracker_index | grep -v beta | grep iso | cut -d '>' -f 8 > ${UBUNTU}.new
diff -q ${UBUNTU} ${UBUNTU}.new > /dev/null || UPDATES="${UPDATES} Ubuntu"

# Report which torrents have updates, if any
if [ -n "${UPDATES}" ]; then
  echo ${UPDATES}
  exit 1
fi

# We made it
rm -f ${UBUNTU}.new
exit 0
