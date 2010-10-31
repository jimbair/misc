#!/bin/bash
# A quick script to test if any of the dev team mirrors
# are either down or passing off bad things to users.

filename='PwnageTool_4.1.2.dmg'
page='http://blog.iphone-dev.org/post/1359246784/20102010-event'
sum='e8f4d590c8fe62386844d6a2248ae609'
temp="$(mktemp)"
results="$(mktemp)"

# Clean up after ourselves if killed.
leave() {
    echo 'Caught SIGINT, Exiting.'
    rm -f ${temp} ${results}
    exit 1
}

trap leave 2

# Check for script dependencies
echo -n "Checking for dependencies..."

# Seperate check for mktemp
if [ -z "${temp}" -o -z ${results} ]; then
    echo 'failed.'
    echo 'Unable to create our temp files. Check mktemp.' >&2
    exit 1
fi

# Check other apps
for prog in wget md5sum sed awk basename; do
    ${prog} --- &>/dev/null
    if [ "$?" -eq 127 ]; then
        echo 'failed.'
        echo "Please install ${prog} to run this script." >&2
        exit 1
    fi
done

echo -e 'done.\n'

# Create our results header
cat << EOHEADER > ${results}
PwnageTool Public Mirror Integrity Test
Created by $(basename $0)
Test ran on: $(date)
File/Sum: ${filename}/${sum}
Page scanned: ${page}

Source can be found at:
http://github.com/tsuehpsyde/misc/blob/master/bash/devteam_checker.sh

--
EOHEADER

# Screen scrape to find the public mirrors.
for url in $(wget -O- ${page} 2>/dev/null | \
             grep "${filename}\"" | cut -d '"' -f 2 ); do

    # If our file is here, remove it.
    if [ -s "${temp}" ]; then
        rm -f ${temp}
    fi

    # Remove any trailing spaces.
    url="$(echo ${url} | sed s/${filename}%20/${filename}/)"

    # Fetch our PwnageTool File
    wget ${url} -O ${temp} # Leave status so user can watch.
    ec="$?"

    # Check wget before we parse anything
    # No problems from server
    if [ ${ec} -eq 0 ]; then
        # Time to check our file
        if [ ! -s "${temp}" ]; then
            status='Empty file'
        elif [ "$(md5sum ${temp} | awk '{print $1}')" != "${sum}" ]; then
            status='Checksum mismatch'
        else
            status='OK'
        fi

    # 404
    elif [ ${ec} -eq 8 ]; then
        status='File Missing'
    # Any unknown errors
    else
        status='Unknown Error'
    fi

    # Print our result
    echo -e "\nURL:    ${url}" >> ${results}
    echo "Status: ${status}" >> ${results}
done

# Print, clean up and exit
clear
cat ${results}
rm -f ${temp} ${results}
exit 0
