#!/bin/bash
# In case our speedtest result seems a bit off and it was a hiccup

echo -n 'Running speedtest...'
SPEEDTEST=$(/usr/bin/speedtest)

# In case it's missing or something breaks
if [[ $? -ne 0 ]]; then
  echo "failed." >&2
  echo "Speedtest failed to run. Exiting." >&2
  exit 1
fi

# Fix formatting
sed 's/\r//g' <<< ${SPEEDTEST} > /tmp/speedtest.log
echo 'done!'

# Present the update
echo
echo "Existing:"
cat /home/jim/log/speedtest.log
echo
echo '------------------------------------------------------------------------------------------------------'
echo
echo "New:"
cat /tmp/speedtest.log
echo

# Ask if we want to update or toss it
read -p 'Would you like to update? ' yn
case $yn in
   [Yy]* ) mv /tmp/speedtest.log /home/jim/log/speedtest.log; exit;;
   * ) rm /tmp/speedtest.log; exit;;
esac
