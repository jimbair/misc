#!/bin/bash
# Check for updates to torrents for our mirror

# Checks for release found in current directory
DEBIAN='11.1.0'
# Check for next release to show up as there is no current directory to look for
FEDORA='36'
# Checks for release found in current directory
CENTOS='8.5.2111'
# Alma only use the first two numbers
ALMA='8.5'
# Don't forget about 7
CENTOS7='2009'
# Ubuntu makes this hard so we scrape the torrent tracker and diff it
UBUNTU='/tmp/ubuntu-torrents.txt'

# Run the checks
curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -q "${DEBIAN}" || exit 1
curl -s https://mirror.rackspace.com/fedora/releases/ | grep -q "${FEDORA}" && exit 2
curl -s https://mirror.rackspace.com/centos/8/isos/x86_64/ | grep -q "${CENTOS}" || exit 3
curl -s https://mirror.rackspace.com/almalinux/8/isos/x86_64/ | grep -q "${ALMA}" || exit 4
curl -s https://mirror.rackspace.com/centos/7/isos/x86_64/ | grep -q "${CENTOS7}" || exit 5

# Create temp file if missing
if [ ! -s "${UBUNTU}" ]; then
  curl -s https://torrent.ubuntu.com/tracker_index | grep iso | cut -d '>' -f 8 > ${UBUNTU} || exit 6
  exit 0
fi

# See what has changed in Ubuntu and clean-up if no changes
curl -s https://torrent.ubuntu.com/tracker_index | grep iso | cut -d '>' -f 8 > ${UBUNTU}.new
diff -q ${UBUNTU} ${UBUNTU}.new > /dev/null || exit 7
rm -f ${UBUNTU}.new

# We made it
exit 0
