#!/bin/bash
# Function to pause a script using sleep, but printing a period for each second.
#
# v1.1 - Changed from -z $1 || -n $2 to $# -ne 1 for input validation.
# v1.0 - Initial writing of function
# 
# Copyright (C) 2008-2009  James Bair <james.d.bair@gmail.com>
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

pause() {
	# Make sure we got proper input
	if [ $# -ne 1 ]; then
		echo 'ERROR: Must be called with one numerical variable.' >&2
		exit 1
	fi

	# Declare our variable
	num=$1
	
	# Ensure we got a number
	numcheck=$(echo $num | sed '/[^0-9]/d')
	if [ -z "$numcheck" ]; then
		echo 'ERROR: Our numerical variable *MUST* be an integer (e.g. 1, 7, 15, etc.)' >&2
		echo 'Exiting.' >&2
		exit 1
	# If we have a number, let's do the deed
	else
		echo -n "Pausing for $numcheck seconds"
		# Print a period and increment down one, go until zero
		while [ "$numcheck" -gt 0 ]; do
			# Print with a newline if our last period
			sleep 1
			if [ "$numcheck" -ne 1 ]; then
				echo -n .
			else
				echo .
			fi
			numcheck=$(($numcheck - 1))
		done
	fi
}
