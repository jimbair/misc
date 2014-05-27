#!/bin/bash
# Basic script to stop/start folding@home.
# Built for my needs - expecting ~/folding/ to exist.
# Validate inputs
if [ $# -ne 1 ]; then
    echo "Usage: $(basename $0) start|stop"
    exit 1
fi

if [ $1 != 'start' ]; then
    if [ $1 != 'stop' ]; then
        if [ $1 != 'status' ]; then
            echo "Usage: $(basename $0) start|stop|status"
            exit 1
        fi
    fi
fi

# Start
if [ $1 == 'start' ]; then
    # Make sure it's not running and that it's actually installed
    ps aux | grep fah6 | grep -q -v grep
    if [ $? -eq 0 ]; then
        echo "Folding already running."
        exit 0
    elif [ ! -d ${HOME}/folding ]; then
        echo "Folding is not installed!"
        exit 1
    fi

    cd ${HOME}/folding; ./fah6 -smp &>/dev/null &
    echo "Folding started."
# Stop
elif [ $1 == 'stop' ]; then
    ps aux | grep fah6 | grep -q -v grep
    if [ $? -eq 1 ]; then
        echo "Folding already stopped."
        exit 0
    fi
    pkill fah6
    echo "Folding stopped."
# Status
elif [ $1 == 'status' ]; then
    ps aux | grep fah6 | grep -q -v grep
    if [ $? -eq 0 ]; then
        echo "Folding is running."
        exit 0
    else
        echo "Folding is stopped."
        exit 0
    fi
fi
