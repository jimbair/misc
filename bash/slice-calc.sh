#!/bin/bash
# A great example of functional but terrible code.
# People who write code like this are bad people.
# Wanted to write this anyway, so I figured I'd
# cut as many corners as possible as an example. =)
#
# Calculates value of each slice at slicehost.
#
# See, no need for perl to make yucky code. Enjoy. =)
calc(){
    [ $# -eq 1 ] || return 0
    echo "scale=2; $1" | bc -q | tr -d '\n'
}
GB='first'
first='yes'
for i in bc curl; do
    $i --help &>/dev/null ; [ $? -eq 127 ] && echo "missing $i" && exit 127
done
for i in $(curl www.slicehost.com 2>/dev/null | egrep -A 5 '[0-9]G?B?[[:space:]]slice' | grep -v 'manage.slicehost.com' | grep -v '^--$' | sed 's/ //g'); do
    [ -z "$i" ] && echo "Something broke." && exit 1
    if [ -n "$(echo $i | grep '\$')" ]; then
        if [ -n "$name" -a -n "$mem" -a -n "$bw" -a -n "$disk" ]; then
            cost="$(echo $i | cut -d '$' -f 2 | cut -d '<' -f 1)"
            [ "${first}" == 'yes' ] || echo -e '\n' && first='no'
            echo "$name - \$$cost gets you ${mem}MB RAM, ${disk}GB Disk, ${bw}GB BW"
            echo "Value:"
            echo -n "Memory: $"
            calc "$cost / $mem"
            echo " per MB"

            echo -n "Disk: $"
            calc "$cost / $disk"
            echo " per GB"

            echo -n "Bandwidth: $"
            calc "$cost / $bw"
            echo " per GB"

            continue
        else
            echo "Something broke."
            exit 1
        fi
    fi
    [ -n "$(echo $i | grep slice)" ] && name="$(echo $i | cut -d '>' -f 3 | cut -d '<' -f 1 | sed 's/slice/ slice/g')" && continue
    [ -n "$(echo $i | grep MB)" ] && mem="$(echo $i | egrep -o '[0-9][0-9]*')" && continue
    if [ -n "$(echo $i | grep GB)" ]; then
        value="$(echo $i | egrep -o '[0-9][0-9]*')"
        if [ $GB == 'first' ]; then
            GB='second'
            disk="$value"
        elif [ $GB == 'second' ]; then
            GB='first'
            bw="$value"
        else
            echo "Something broke."
            exit 1
        fi
    fi
done
exit 0
