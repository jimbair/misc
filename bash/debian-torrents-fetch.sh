#!/bin/bash
# A script to fetch all of the current debian torrents
# Leverages rsync for speed; this is only run when a new release
# is dropped and I need to update mirror.tsue.net's torrents

# Create two directories, one for the rsync target and one to easily grab all torrents
mkdir -p torrents_tree torrents

# Sync the tree (only downloads .torrent files)
rsync -am --include='*/' --include='*.torrent' --exclude='*' rsync://cdimage.debian.org/debian-cd/current/ torrents_tree/ || exit 1

# Move torrent files into a single directory
find torrents_tree -type f -name '*.torrent' -exec mv '{}' torrents/ \; || exit 2

# Remove tree (which should now be empty)
rm -r torrents_tree || exit 3
