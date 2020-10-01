#!/bin/bash
# A script to fetch all debian torrents, since they make this
# ridiculously difficult to do for some reason. This script
# is 100% a hack - it fetches all torrents twice, and lets
# find sort it out. The torrents are dropped into the torrents folder.
#
# I use this to keep a fresh set of torrents seeding on tsue.net
#
# v1.1


# Grab them all
wget -r -A.torrent https://cdimage.debian.org/debian-cd/current/ || exit 1

# Move all the torrents into a folder
mkdir torrents
find cdimage.debian.org -type f -name '*.torrent' -exec mv '{}' torrents/ \; || exit 2
rm -fr cdimage.debian.org
