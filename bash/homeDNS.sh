#!/bin/bash
# A small script using rsdns to update our home DNS record on Rackspace Cloud DNS
DNS='home.tsue.net'
PATH='/home/jim/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
which rsdns > /dev/null 2>&1 || exit 1

/bin/date
IPV4=$(curl --silent ipv4.icanhazip.com)
IPV6=$(curl --silent ipv6.icanhazip.com)
[ -n "${IPV4}" ] && [ -z "$(host $DNS | grep $IPV4)" ] && rsdns a -i $IPV4 -n $DNS -U
[ -n "${IPV6}" ] && [ -z "$(host $DNS | grep $IPV6)" ] && rsdns aaaa -i $IPV6 -n $DNS -U
exit 0
