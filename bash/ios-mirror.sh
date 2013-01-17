#!/bin/bash
# Simple script to mirror all iOS IPSW files locally from Apple's servers.
# Uses both the iPhone Wiki as well as Apple's list of restore files.

appleList='http://ax.phobos.apple.com.edgesuite.net/WebObjects/MZStore.woa/wa/com.apple.jingle.appserver.client.MZITunesClientCheck/version'
ipswList='http://theiphonewiki.com/wiki/Firmware'

# Check URL and fetch if we don't have the file.
# Expects a URL to be passed as $1
checkAndFetch() {
    # Find the filename using awk
    filename="$(echo "$1" | awk -F '/' '{print $NF}')"
    checksum="${filename}.sha1sum"
    # If we have it, skip.
    if [ -s "${filename}" -a -s "${checksum}" ]; then
        echo "Skipping ${filename}."
    # Look for missing checksum
    elif [ -s "${filename}" -a ! -s "${checksum}" ]; then
        echo "Checksum file ${checksum} missing. Generating..."
        shasum ${filename} > ${checksum}
        if [ $? -eq 0 ]; then
            echo 'done.'
        else
            echo 'failed.' >&2
            exit 1
        fi
    # If not, fetch it and sha1sum it locally.
    else
        wget $1
        if [ $? -ne 0 ]; then
            echo "Failed to fetch our file. Aborting." >&2
            exit 1
        fi
        echo -n "Generating ${checksum}..."
        shasum ${filename} > ${checksum}
        if [ $? -eq 0 ]; then
            echo 'done.'
        else
            echo 'failed.' >&2
            exit 1
        fi
    fi
}

# Find each URL to the IPSW files on TheiPhoneWiki.
echo "Beginning sync from the iPhone Wiki's list:"
for url in $(curl --silent "${ipswList}"  | grep 'Restore.ipsw' | cut -d '"' -f 6); do
    checkAndFetch "${url}"
done

# Find each URL to the IPSW files on Apple's list.
echo "Beginning sync from Apple's list:"
for url in $(curl --silent "${appleList}" | grep 'Restore.ipsw' | grep 'http://' | cut -d '>' -f 2 | cut -d '<' -f 1 | sort -u); do
    checkAndFetch "${url}"
done

exit 0
