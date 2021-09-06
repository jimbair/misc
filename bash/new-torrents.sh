#!/bin/bash
# Check for updates to torrents for our mirror

# Checks for release found in current directory
DEBIAN='11.0.0'
# Check for next release to show up as there is no current directory to look for
FEDORA='35'
# Checks for release found in current directory
CENTOS='8.4.2105'
# Rocky and Alma only do the first two
ROCKY='8.4'
ALMA="${ROCKY}"
# Don't forget about 7
CENTOS7='2009'
# Ubuntu makes this hard so we scrape the torrent tracker and sha1sum it
# Generated Sep 6th 2021
UBUNTU='5e304d75e6c39338572f0dea4aa6181fa7804603'

# Run the checks
curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -q "${DEBIAN}" || exit 1
curl -s https://mirror.rackspace.com/fedora/releases/ | grep -q "${FEDORA}" && exit 1
curl -s https://mirror.rackspace.com/centos/8/isos/x86_64/ | grep -q "${CENTOS}" || exit 1
curl -s https://download.rockylinux.org/pub/rocky/8/isos/x86_64/ | grep -q "${ROCKY}" || exit 1
curl -s https://mirror.rackspace.com/almalinux/8/isos/x86_64/ | grep -q "${ALMA}" || exit 1
curl -s https://mirror.rackspace.com/centos/7/isos/x86_64/ | grep -q "${CENTOS7}" || exit 1
curl -s https://torrent.ubuntu.com/tracker_index | grep iso | cut -d '>' -f 8 | sha1sum | grep -q "${UBUNTU}" || exit 1

# We made it
exit 0
