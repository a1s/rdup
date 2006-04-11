#!/bin/bash
#
# Copyright (c) 2005, 2006 Miek Gieben
# See LICENSE for the license
#
# zip rdup -c's output

set -o nounset

S_ISDIR=16384   # octal: 040000 (This seems to be portable...)
S_ISLNK=40960   # octal: 0120000
S_MMASK=4095    # octal: 00007777, mask to get permission
PROGNAME=$0
OPT=""

_echo2() {
        echo "** $PROGNAME: $1" > /dev/fd/2
}

cleanup() {
        _echo2 "Signal received while processing \`$path', exiting"
        if [[ ! -z $TMPDIR ]]; then
                rm -rf $TMPDIR
        fi
        exit 1
}
# trap at least these
trap cleanup SIGINT SIGPIPE

usage() {
        echo "$PROGNAME [-d]"
        echo
        echo "encrypt or decrypt the file's contents"
        echo
        echo OPTIONS:
        echo " -d        decrypt the files"
        echo " -h        this help"
        echo " -V        print version"
}

version() {
        echo "$PROGNAME: @PACKAGE_VERSION@ (rdup-utils)"
}

_stat_size() {
        case $OSTYPE in
                linux*)
                        echo $(stat --format "%s" "$@")
                ;;
                freebsd*)
                        echo $(stat -f "%z" "$@")
                ;;
        esac
}

while getopts "dVh" o; do
        case $o in
                d) OPT="-d";;
                h) usage && exit;;
                V) version && exit;;
                \?) usage && exit;;
        esac
done
shift $((OPTIND - 1))

# 1 argument keyfile used for encryption
if [[ $# -eq 0 ]]; then
        _echo2 "Need a keyfile as argument"
        exit 1
fi
if [[ ! -r $1 ]]; then
        _echo2 "Cannot read keyfile \`$1': failed"
        exit 1
fi

TMPDIR=`mktemp -d "/tmp/rdup.backup.XXXXXX"`
if [[ $? -ne 0 ]]; then
        _echo2 "** $0: mktemp failed" 
        exit 1
fi
chmod 700 $TMPDIR

while read mode uid gid psize fsize
do
        dump=${mode:0:1}        # to add or remove
        mode=${mode:1}          # st_mode bits
        typ=0
        path=`head -c $psize`   # gets the path
        if [[ $(($mode & $S_ISDIR)) == $S_ISDIR ]]; then
                typ=1;
        fi
        if [[ $(($mode & $S_ISLNK)) == $S_ISLNK ]]; then
                typ=2;
        fi
        if [[ $dump == "+" ]]; then
                # add
                case $typ in
                        0)      # REG
                        if [[ $fsize -ne 0 ]]; then
                                # catch 'n crypt
                                head -c $fsize | \
                                mcrypt $OPT -F -f "$1" -a blowfish > $TMPDIR/file.$$.enc || \
                                exit 1

                                newsize=_stat_size $TMPDIR/file.$$.enc
                                echo "$dump$mode $uid $gid $psize $newsize"
                                echo -n "$path"
                                cat $TMPDIR/file.$$.enc
                                rm -f $TMPDIR/file.$$.enc
                        else
                                # no content
                                echo "$dump$mode $uid $gid $psize $fsize"
                                echo -n "$path"
                        fi
                        ;;
                        1)      # DIR
                        echo "$dump$mode $uid $gid $psize $newsize"
                        echo -n "$path"
                        ;;
                        2)      # LNK, target is in the content!
                        target=`head -c $fsize`
                        echo "$dump$mode $uid $gid $psize $fsize"
                        echo -n "$path"
                        echo -n "$target"
                        ;;
                esac
        else
                # there is no content
                echo "$dump$mode $uid $gid $psize $fsize"
                echo -n "$path"
        fi
done

rm -rf $TMPDIR
