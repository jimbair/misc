#!/bin/bash
# Script to parse apache's logs and find
# bots that are scanning the server to find
# protected things.
hostsDeny='/etc/hosts.deny'
prog="$(basename $0)"
temp="$(mktemp)"
webFile='/var/log/apache2/access_log'

# Choose your method of choice
#method='tcpwrappers'
method='iptables'

# Strings to search for. Separate strings by spaces.
# Strings are not case sensitive.
ourStrings='myadmin w00tw00t.at.ISC.SANS.DFind fastenv GET[[:space:]]http://'

# Start up validations
if [ $UID -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
elif [ ! -s "${webFile}" ]; then
    echo "ERROR: Our file ${webFile} is empty or missing." >&2
    exit 1
else
    echo "INFO: ${prog} started at $(date)"
fi

# Find IPs searching for various strings like phpMyAdmin, DLink config, etc.
for string in ${ourStrings}; do
    echo -n "INFO: Searching for our offending IPs against ${string}..."

    # We use awk to avoid any remote injections from attackers.
    # Also the IP check is okay, but not great.
    ourIPs="$(egrep -i ${string} ${webFile} | awk '{print $1}' | \
    grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*' | sort -u)"

    echo 'done.'

    # Make sure we have IPs
    if [ -z "${ourIPs}" ]; then
        echo "INFO: No offending IPs found."
        continue
    else
        echo -e "Found the following IPs:\n${ourIPs}\n"
    fi

    # Build our global IP list from all the strings we check against
    for ip in ${ourIPs}; do
    if [ -z "${allIPs}" ]; then
        allIPs="${ip}"
    else
        # Make sure a previous string didn't find our IP
        echo ${allIPs} | grep "${ip}" &>/dev/null || allIPs="${allIPs} ${ip}"
    fi
    done
done

# Start blocking some IPs
for ip in ${allIPs}; do
    echo "INFO: Working on ${ip} via ${method}"
    # Add the IPs we found into hosts.deny
    if [ "${method}" == 'tcpwrappers' ]; then

        # Skip if we already have an entry
        grep "${ip}" ${hostsDeny} &>/dev/null && \
        echo -e "INFO: Skipping ${ip}\n" && continue

        # Adding into hosts.deny
        echo -n "INFO: Adding ${ip} to ${hostsDeny}..."
        echo "ALL: ${ip}" >> ${hostsDeny}
        echo -e 'done.\n'
    # Add the IPs we found into iptables
    elif [ "${method}" == 'iptables' ]; then

        # Skip if we already have an entry
        iptables -n -L | grep "${ip}" &>/dev/null && \
        echo -e "INFO: Skipping ${ip}\n" && continue

        # Adding into iptables
        echo -n "INFO: Adding ${ip} into iptables..."
        iptables -I INPUT -s ${ip} -j DROP &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e 'done.\n'
        else
            echo 'failed.'
            echo 'ERROR: iptables failed to add our rule.' >&2
            exit 1
        fi
    # Any other methods are unsupported.
    else
        echo "ERROR: Unsupported method '${method}'." >&2
        exit 1
    fi
done

# All done.
echo "INFO: ${prog} finished at $(date)"
exit 0
