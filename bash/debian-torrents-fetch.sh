#!/bin/bash
# A script to fetch all debian torrents, since they make this
# ridiculously difficult to do for some reason. This script
# is 100% a hack - it fetches all torrents twice, and lets
# the find sort it out. Be sure to run this in a folder. =) 
#
# I use this to keep a fresh set of torrents seeding on tsue.net
#
# v1.0


# Grab them all
wget -r -A.torrent https://cdimage.debian.org/debian-cd/current/ || exit 1

# Move all the torrents into cd
find  . -type f -name '*.torrent' -exec mv '{}' . \;
