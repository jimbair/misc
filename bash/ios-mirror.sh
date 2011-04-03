#!/bin/bash
# Simple script to mirror all iOS IPSW files locally from Apple's servers.
# Uses both the iPhone Wiki as well as Apple's list of restore files.

appleList='http://ax.phobos.apple.com.edgesuite.net/WebObjects/MZStore.woa/wa/com.apple.jingle.appserver.client.MZITunesClientCheck/version'
ipwList='http://theiphonewiki.com/wiki/index.php?title=Firmware'

# Check URL and fetch if we don't have the file.
# Expects a URL to be passed as $1
checkAndFetch() {
    # Find the filename using awk
    filename="$(echo "$1" | awk -F '/' '{print $NF}')"
    # If we have it, skip.
    if [ -s "${filename}" ]; then
        echo "Skipping $filename - already exists."
    # If not, fetch it and sha1sum it locally.
    else
        wget $url && shasum $filename > $filename.sha1sum
    fi
}

# Find each URL to the IPSW files on TheiPhoneWiki.
echo 'Beginning sync from the iPhone Wiki List:'
for url in $(curl --silent "${ipwList}"  | grep 'Restore.ipsw' | cut -d '"' -f 2); do
    checkAndFetch "${url}"
done

# Find each URL to the IPSW files on Apple's list.
echo "Beginnings sync from Apple's list:"
for url in $(curl --silent "${appleList}" | grep 'Restore.ipsw' | grep 'http://' | cut -d '>' -f 2 | cut -d '<' -f 1 | sort -u); do
    checkAndFetch "${url}"
done

exit 0
