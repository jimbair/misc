#!/bin/bash
# Quick script to fetch any new files on the DevTeam blog.
# Supports downloading redsn0w and PwnageTool currently.

# Currently using redsn0w beta (tethered)
#rsURL='http://blog.iphone-dev.org/tagged/redsn0w'
rsURL='http://blog.iphone-dev.org/redsn0w-iOS5/'
ptURL='http://blog.iphone-dev.org/tagged/PwnageTool'
wgetOpts='-o /dev/null -O -'

fetchLatest() {

    done=''
    for url in $@; do
        filename="$(echo ${url} | awk -F '/' '{print $NF}')"
        # Skip this file if we already got it.
        if [ -n "$(echo ${done} | grep ${filename})" -o -s "${filename}" ]; then
            continue
        fi
        # Make sure it fetched safely
        wget -O ${filename} ${url}
        if [ $? -ne 0 ] || [ ! -s "${filename}" ]; then
            rm -f ${filename}
        else
            # Print checksum to stdout to validate. Works on Mac/Linux.
            platform="$(uname)"
            if [ "${platform}" == 'Linux' ]; then
                sha1sum ${filename}
            elif [ "${platform}" == 'Darwin' ]; then
                shasum ${filename}
            else
                echo "Unsupported platform. Skipping sha1 checksum generation." >&2
            fi
            # Add completed file into our list
            done="${done} ${filename}"
        fi
    done

}

echo -n "Finding our URLs..."
rsURLs="$(wget ${wgetOpts} ${rsURL} | grep redsn0w | grep .zip | sort -u | cut -d '?' -f -1 | cut -d \" -f 2-)"
ptURLs="$(wget ${wgetOpts} ${ptURL} | grep PwnageTool | grep .dmg | cut -d \" -f 2 | grep -v torrent)"
echo 'done.'

# redsn0w
if [ -n "${rsURLs}" ]; then
    fetchLatest ${rsURLs}
else
    echo "No redsn0w URLs found."
fi

# PwnageTool
if [ -n "${ptURLs}" ]; then
    fetchLatest ${ptURLs}
else
    echo "No PwnageTool URLs found."
fi

# All done
exit 0
