#!/bin/bash
# Simple script to update multiple Wordpress installs
# via local (SSH) access. Adjust base and targets as needed.
url='http://wordpress.org/latest.tar.gz'
tgz="$(echo $url | cut -d '/' -f 4-)"
tmp="$(mktemp -d)"

base='/var/www/'
targets='www.myblog.com anotherblog.com'

cd ${tmp}
if [ $? -ne 0 ]; then
    echo "Temp directory failed." >&2
    exit 1
fi

wget ${url}
if [ $? -ne 0 ]; then
    echo "Download of new WP failed." >&2
    exit 1
fi

tar xzvf ${tgz}
if [ $? -ne 0 ]; then
    echo "Extraction of new WP failed." >&2
    exit 1
else
    rm -f ${tgz}
fi

cd wordpress
if [ $? -ne 0 ]; then
    echo "Cannot find wordpress folder." >&2
    exit 1
fi

for target in ${targets}; do
    ourFolder="${base}${target}/"
    cp -r * ${ourFolder}
    if [ $? -ne 0 ]; then
        echo "Update for $ourFolder failed." >&2
        exit 1
    else
        echo "Updated $ourFolder successfully."
    fi
done

# Sanity check against rm -fr
if [ "${tmp}" == '/' ]; then
    echo "Aborting cleanup." >&2
    exit 1
fi

cd ${HOME} && rm -fr ${tmp}
exit 0
