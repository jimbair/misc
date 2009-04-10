#!/bin/bash
# Script to find your public MAC address.
# v1.1 - Modified to use /sbin/ip and nothing else
# David Cantrell 8/31/2008
# v1.0 - Initial script (mymac.sh)
# 
# Copyright (C) 2008  James Bair <james.d.bair@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

IP=/sbin/ip

${IP} >/dev/null 2>&1
if [ $? -eq 127 ]; then
    echo "${IP} command not found, exiting." >&2
    exit 1
fi

get_external_interface() {
    ${IP} route list | while read routename a b c devname remainder ; do
        if [ "${routename}" = "default" ]; then
            echo ${devname}
            break
        else
            continue
        fi
    done
}

get_macaddr() {
    interface="${1}"
    if [ -z "${interface}" ]; then
        return
    fi

    ${IP} link show ${interface} | while read desc macaddr remainder ; do
        if [ "${desc}" = "link/ether" ]; then
            echo "${macaddr}"
            break
        else
            continue
        fi
    done
}

interface="$(get_external_interface)"

if [ -z "${interface}" ]; then
    echo "No public interface found, cannot determine MAC address." >&2
    exit 1
fi

get_macaddr ${interface}
