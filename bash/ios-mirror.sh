#!/bin/bash
# Simple script to mirror all iOS IPSW files locally from Apple's servers.

mirrorList='http://ax.phobos.apple.com.edgesuite.net/WebObjects/MZStore.woa/wa/com.apple.jingle.appserver.client.MZITunesClientCheck/version'

# Find each URL to the IPSW files.
for url in $(curl --silent "${mirrorList}" | grep 'http://' | grep 'Restore.ipsw' | cut -d '>' -f 2 | cut -d '<' -f 1 | sort -u); do
    # Find the filename using awk
    filename="$(echo "${url}" | awk -F '/' '{print $NF}')"
    # If we have it, skip.
    if [ -s "${filename}" ]; then
        echo "Skipping $filename - already exists."
    # If not, fetch it and sha1sum it locally.
    else
        wget $url && shasum $filename > $filename.sha1sum
    fi

done

exit 0
