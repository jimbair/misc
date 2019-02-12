#!/bin/bash
server='jdc'
cd /etc/pihole || exit 1
for i in blacklist.txt whitelist.txt regex.list; do
    [[ ! -f $i ]] && exit 2
    localsum=$(sha1sum $i | cut -d ' ' -f 1)
    remotesum=$(ssh ${server} sha1sum pisync/${i} | cut -d ' ' -f 1)
    if [[ ${localsum} == ${remotesum} ]]; then
        echo "$i matches on ${server}"
	continue
    fi
    echo "Updating $i"
    scp $i jdc:pisync/ || exit 3
done
