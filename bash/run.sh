#!/bin/bash
#
# run function to check exit codes
#
# *** NOTICE ***
# This function DOES NOT WORK when using stdin/stdout/stderr
#
# For example:
#    run gzip -c /home/user/filename.ext > /tmp/filename.ext
#
# The above example will fail. 
#
# v.22 - Added catch for cd (and able to add later as needed)
# v.21 - Only call echo if non-null response
# v.2  - Added 127 code support
#      - Added a few more comments
# v.1  - Initial Script
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

run() {
    local app="$1"
    local com="$*"
    local exc ec
    local -a unsupported=(cd exec source)

    # Validate before running anything
    for u in "${unsupported[@]}"; do
        if [[ "$app" == "$u" ]]; then
            echo "ERROR: $app is not supported by run()" >&2
            echo "Exiting." >&2
            return 1
        fi
    done

    # Execute, capturing both streams; exit code captured immediately after
    exc=$("$@" 2>&1)
    ec=$?

    case $ec in
        0)
            [[ -n "$exc" ]] && echo "$exc"
            ;;
        127)
            echo -e "ERROR: The following application was not found in PATH:\n\n${app}\n\nThis application was called when trying to run the following command:\n\n${com}\n\nExiting." >&2
            return $ec
            ;;
        *)
            echo -e "ERROR: We received an exit code of $ec when running the following command:\n\n${com}\n\nError message given:\n\n${exc}\n\nExiting." >&2
            return $ec
            >&2
            ;;
    esac
}
