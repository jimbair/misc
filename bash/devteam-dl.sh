#!/bin/bash
# Quick script to fetch any new files on the DevTeam blog.
# Supports downloading redsn0w and PwnageTool currently.
# Need to be smarter about:
#  if files already exist.
#  checking each version of PwnageTool
#
# But that's for later I guess. Just wanted to get this into the repo.

url='http://blog.iphone-dev.org/'
wgetOpts='-o /dev/null -O -'

# redsn0w - fetch everything we can.
rsURLs="$(wget $wgetOpts $url | grep redsn0w | grep .zip | sort -u | cut -d '?' -f -1 | cut -d '"' -f 2-)"
if [ -n "${rsURLs}" ]; then
    for url in ${rsURLs}; do
        filename="$(echo $url | awk -F '/' '{print $NF}')"
        wget -O ${filename} ${url}
        [ ! -s "${filename}" ] && rm -f ${filename}
    done
fi

# PwnageTool - Try one URL at a time until we get a good one.
ptURLs="$(wget $wgetOpts $url | grep PwnageTool | grep .dmg | cut -d \" -f 2 | grep -v torrent)"
if [ -n "${ptURLs}" ]; then
    for url in ${ptURLs}; do
        filename="$(echo $url | awk -F '/' '{print $NF}')"
        wget -O ${filename} ${url}
        if [ ! -s "${filename}" ]; then
            rm -f ${filename}
        else
            sha1sum ${filename}
            break
        fi
    done
fi

# All done
exit 0
