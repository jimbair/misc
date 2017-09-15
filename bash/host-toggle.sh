#!/bin/bash
# A simple script to comment in/out the "Host *" section of your local ssh config.
# Useful if you use a laptop to ssh both at home and at work and don't want to 
# constantly swap out ProxyCommand configs or make 2 configs per server.
#
# I did some basic tests that I could think of but feel free to report any bugs.
# Was written on a Mac so who knows if there's something weird between Mac and Linux.
#
# v1.2
# Jim Bair

# Lock file to avoid concurrency issues if you're bundling this
# command with clusterssh.
lockfile="/tmp/$(basename $0).lock"
if [ -f "${lockfile}" ]; then
    # Exit silently since we're assuming concurrency
    exit 0
else
    touch $lockfile
    if [ $? -ne 0 ]; then
        echo "Something went wrong creating our lockfile. Exiting."
        exit 1
    fi
fi

# Find our SSH Config
filename="$HOME/.ssh/config"
if [ ! -s $filename ]; then
    echo "ERROR: Cannot find $filename - Exiting."
    rm -f $lockfile
    exit 1
fi

# Validate our inputs and report usage if needed.
if [ $# -gt 1 ] || [ $# -eq 1 ] && [ "$1" != "status" ]; then
    echo "ERROR: Usage: $(basename $0) [status]"
    rm -f $lockfile
    exit 1
fi

# Check the status of our config, if asked.
if [ $# -eq 1 ] && [ "$1" == 'status' ]; then
    egrep -q '#Host \*' $filename
    if [ $? -eq 0 ]; then
        echo "Status: not active"
    else
        echo "Status active"
    fi
    rm -f $lockfile
    exit 0
fi

# Store our new config into temp then move it into place later.
ourTemp=$(mktemp)
if [ $? -ne 0 ]; then
    echo "ERROR: Unable to create temp file. Exiting."
    rm -f $lockfile
    exit 1
fi

# Let's preserve indentation in the config file
OLDIFS="$IFS"
IFS=''

# Walk line by line, either passing lines or editing lines.
# We are looking for the catch all host "Host *" to start, then 
# either adding a # or removing the first character to strip the #
HOSTBLOCK=no
while read -r line
do
    # Looking for the host block.
    if [ "$HOSTBLOCK" == 'no' ]; then
        # Found the block!
        if [ -n "$(echo $line | egrep  'Host \*')" ]; then
            HOSTBLOCK=yes
            # Now see if we are swapping the catch all in or out
            if [ -n "$(echo $line | egrep  '^Host \*')" ]; then
                echo -n "Disabling bastion host block..."
                STYLE='out'
                echo "#${line}" >> $ourTemp
            else
                echo -n "Enabling bastion host block..."
                STYLE='in'
                echo "${line:1}" >> $ourTemp
            fi
        else
            # Not the Host block so just pass it through
            echo "$line" >> $ourTemp
            continue
        fi
    else
        # If empty, we are at the end of the Host * section
        if [ -z "$(echo $line)" ]; then
            HOSTBLOCK=no
            echo >> ${ourTemp}
            continue
        fi

        # If here, you are in the host block AND modifying the lines
        # based on the style decided above.

        # Comment out lines (easy enough)
        if [ "$STYLE" == 'out' ]; then
            echo "#${line}" >> $ourTemp
        # Otherwise, strip out the comment character.
        else
            # Small sanity check
            if [ -z "$(echo $line | egrep '^#')" ]; then
                echo "ERROR: Expected a commented out line in the host block but was surprised. Exiting." >&2
                rm -f $ourTemp
                exit 1
            fi
            echo "${line:1}" >> $ourTemp
        fi
    fi


done < "$filename"

# Restore the old IFS even though it probably doesn't matter
IFS="$OLDIFS"

# overwrite our config and remove our temp files
cat $ourTemp > $filename
rm -f $ourTemp $lockfile

# All done
echo 'done.'
exit 0
