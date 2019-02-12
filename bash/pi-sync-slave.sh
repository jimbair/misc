#!/bin/bash
# Quick hack to sync remote pi-hole
target='/home/user/pisync'
[[ $UID -eq 0 ]] || exit 1
cd ${target} || exit 2
for i in $(ls); do
    # TODO - Check if sync is needed with sha1sum
    echo -n "Syncing $i"...
    cat $i > /etc/pihole/${i} || exit 3
    echo 'done.'
done
exit 0
