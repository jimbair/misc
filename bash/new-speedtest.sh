#!/bin/bash
# In case our speedtest result seems a bit off and it was a hiccup

echo -n 'Running speedtest...'
/usr/bin/speedtest | sed 's/\r//g' > /tmp/speedtest.log
echo 'done!'
echo
echo "Existing:"
cat /home/jim/log/speedtest.log
echo
echo '------------------------------------------------------------------------------------------------------'
echo
echo "New:"
cat /tmp/speedtest.log
echo
read -p 'Would you like to update? ' yn
case $yn in
   [Yy]* ) mv /tmp/speedtest.log /home/jim/log/speedtest.log; exit;;
   * ) rm /tmp/speedtest.log; exit;;
esac
