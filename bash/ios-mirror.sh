#!/bin/bash
# Simple script to mirror all iOS IPSW files locally from Apple's servers.
# Need to switch over to using awk instead of this crazy loop.

mirrorList='http://ax.phobos.apple.com.edgesuite.net/WebObjects/MZStore.woa/wa/com.apple.jingle.appserver.client.MZITunesClientCheck/version'

# Find each URL to the IPSW files.
for url in $(curl --silent "${mirrorList}" | grep 'Restore' | grep '.ipsw' | grep -v 'protected://' | cut -d '>' -f 2- | cut -d '<' -f -1); do

    # We have to find the file name in the URL first to see if we already have it.
    found=no
    base=6

    while true; do
        # If we've found our filename, see if we need to download it
        if [ "$found" == 'yes' ]; then
            filename="$(echo $url | cut -d '/' -f $base)"
            # If we have it, skip.
            if [ -s "${filename}" ]; then
                echo "Skipping $filename - already exists."
            # If not, fetch it and sha1sum it locally.
            else
                wget $url && shasum $filename > $filename.sha1sum
            fi
            # Next URL please.
            break
        fi

        # If not found, let's see how many slahes we have.
        testing="$(echo $url | cut -d '/' -f $base)"
        if [ -n "${testing}" ]; then
            let base++
        else
            let base--
            found=yes
        fi

    done

done

exit 0
