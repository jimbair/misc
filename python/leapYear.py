#!/usr/bin/python
# Code so Jim can learn how to C like a big boy.
# v0.1

# Import the goods 
import sys

# Our main function.
def main():
    if len(sys.argv) < 2:
        print "ERROR: No years provided!"
        usage()
        sys.exit(1)

    # Validate our inputs and get them results
    for year in sys.argv[1:]:
        validate(year)
        isLeap(year)

# Make sure we're not getting silly things
def validate(year):
    try:
        foo = int(year)
    except ValueError:
        print "ERROR: %s is not a valid year." % (year,)
        sys.exit(1)

    # Let's avoid negative years for now
    if foo < 0:
        print "ERROR: %s is not a valid year." % (year,)
        sys.exit(1)

def isLeap(year):
    # Formula as stolen from Wikipedia
    # https://en.wikipedia.org/wiki/Leap_year
    if int(year) % 4 != 0:
        print "%s is not a leap year." % (year,)
    elif int(year) % 100 != 0:
        print "%s is a leap year." % (year,)
    elif int(year) % 400 != 0:
        print "%s is not a leap year." % (year,)
    else:
        print "%s is a leap year." % (year,)

# Usage
def usage():
    prog = sys.argv[0]
    print "%s - a program to verify a given year is a leap year." % (prog,)
    print "Usage: %s [YEAR] ([YEAR] [YEAR] ...)" % (prog,)
    print "You may provide multiple years to validate at once."

# Allows this program to be used as a library
if __name__ == '__main__':
    main()
