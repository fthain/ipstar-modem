#!/bin/sh

# IPSTAR (Shin Satellite) IPX-5100ME modem setup & monitoring script.
# Version 0.5

# Requires XML::Simple perl module. Mac OS X has it pre-installed.
# Debian/Ubuntu Linux users should $ sudo apt-get install libxml-simple-perl

# Copyright (c) 2013 - 2015 Finn Thain
# fthain@telegraphics.com.au

# See also ipstarlog.py by David Boxall,
# ipstar_satellite_status.php by Sony AK Knowledge Center and
# http://192.168.5.100:8080/xmlcode.js

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


set -e -u

ip=192.168.5.100
# ip=192.168.0.1
url="http://${ip}:8080/xWebGateway.cgi"
jar=$( mktemp -t ipstar-cookie-XXXXXX )
xml=$( mktemp -t ipstar-output-XXXXXX )
user=ADMIN
pass=operator

trap "echo; quit 2" HUP INT QUIT TERM
trap "quit" EXIT


# Cleanup and exit

quit () {
  e=${1:-$?}
  rm -f "$jar" "$xml"
  exit "$e"
}


# curl wrapper

_curl () {
  curl --fail --location -q --raw --silent --show-error "$@"
}


# Requests need cookie authorization

fetch_site_cookie () {
  test -s "$jar" && return 0
  _curl --cookie-jar "$jar" --get "$url" > /dev/null
}

fetch_auth_cookie () {
  fetch_site_cookie
  _curl --cookie-jar "$jar" --cookie "$jar" --referer "$url" \
        --data "User=${user}&Pass=${pass}&Page=report&B1=submit" \
        "${url}?page=report" > /dev/null
}


# Send XML RPC get request

get () {
  fetch_site_cookie
  _curl --cookie "$jar" --referer "$url" \
        --header "Content-type:" --header "Content-type: application/xml" \
        --data "<Get ${1} path=\"${2}\" />" \
        "${url}?post=yes"
}


# Send XML RPC update request

update () {
  fetch_auth_cookie
  _curl --cookie "$jar" --referer "$url" \
        --header "Content-type:" --header "Content-type: application/xml" \
        --data "<Update path=\"${1}\">${2}</Update>" \
        "${url}?post=yes"
}


# Send XML RPC commit request

commit () {
  _curl --cookie "$jar" --referer "$url" \
        --header "Content-type:" --header "Content-type: application/xml" \
        --data "<Commit path=\"${1}\" />" \
        "${url}?post=yes"
}


# Report on XML RPC response

log_rpc () {
  printf "Sending command: $1 $2 ... "
  "$@" > "$xml"
  perl -MXML::Simple -e '
    $x = XMLin q(/dev/stdin);
    if (defined $x->{Succeeded}) {
      print q(ok).$/;
    } else {
      print q(failed: ).$x->{Failed}.$/;
      exit 1;
    }
  ' < "$xml"
}


# Wait for the modem to bring up ethernet link

wait_for_link () {
  printf "Waiting for echo reply from satellite modem ... "
  while true ; do
    ping -q -c 1 "$ip" > /dev/null 2> /dev/null && break
    sleep 2
  done
  echo ok
}


# Wait for the modem HTTP server to come online

wait_for_http () {
  printf "Waiting for satellite modem HTTP server ... "
  while true ; do
    _curl --max-time 4 --get "$url" > /dev/null 2>&1
    case $? in
    0 )
      echo ok
      return 0
      ;;
    7 | 28 | 52 )
      sleep 1
      ;;
    * )
      echo failed
      exit 1
      ;;
    esac
  done
}


# Send reboot command to modem

reboot_modem () {
  echo "Sending command: reboot"
  update /parameters/WWW/CommandInterface/CommandID \
         '<CommandID type="u32" updatescript="sysman reboot">1</CommandID>'
  ping -c 60 "$ip" || true
}


# Report modem status and signal quality

report_modem_status () {
  get 'doc="ConsumerBoxConfig.xml"' /parameters/WWW/STATUS > "$xml"
  perl -MXML::Simple -e '
    $x = XMLin q(/dev/stdin);
    print q(RXSignalStrength: ).$x->{STATUS}{RXSignalStrength}{content}.$/;
    print q(EsN0            : ).$x->{STATUS}{EsN0}{content}.$/;
  ' < "$xml"

  get 'doc="ConsumerBoxConfig.xml"' /parameters/WWW/HOME > "$xml"
  perl -MXML::Simple -e '
    $x = XMLin q(/dev/stdin);
    $k = $x->{HOME}{LoginStatus}{LastMessage}{content};
    $_ = $x->{HOME}{LoginStatus}{LogMessages}{Msg}{$k}{content};
    s/[[:cntrl:]]//g;
    print q(Last Log Message: ).$_.$/;
  ' < "$xml"
}


# Check default route from DHCP server

check_default_route () {
  printf "Checking default route ... "
  for router in $( netstat -nr | perl -ne '/^(default|0.0.0.0)\s+(\S+)/ && print $2.$/' ) ; do
    if test "$router" = "$ip" ; then
      echo ok
      return 0
    fi
  done
  echo "wrong gateway: ${router}"
  return 1
}


# Test name server lookup

test_name_servers () {
  ns=
  for ns in $( perl -ne '/^nameserver\s+([.:0-9a-fA-F]+)$/ && print $1.$/' < /etc/resolv.conf )
  do
    printf "Trying name server ${ns} ... "
    if ping -q -c 1 "$ns" > /dev/null 2>&1 ; then
      if dig +short @"$ns" -x 8.8.8.8 > /dev/null 2>&1 ; then
        echo ok
        return 0
      else
        echo "failed: no records"
      fi
    else
      echo "failed: no echo reply"
    fi
  done
  test -z "$ns" && echo "No name servers configured"
  return 1
}


# Test web connectivity

test_web_servers () {
  for ws in http://google.com/
  do
    printf "Trying web server ${ws} ... "
    _curl --max-redirs 0 --max-time 10 --get "$ws" > /dev/null 2>&1
    case $? in
    0 | 47 )
      echo ok
      return 0
      ;;
    * )
      echo failed
      ;;
    esac
  done
  return 1
}


# Main program

clear
wait_for_link
for arg in "$@" ; do
  case "$arg" in
    --debug )
      wait_for_http
      get 'doc="ConsumerBoxConfig.xml"' /parameters >> "${xml}-debug-volatile"
      get ''                         /parameters >> "${xml}-debug-nonvolatile"
      ;;
    --poll )
      wait_for_http
      while true ; do
        echo
        date
        report_modem_status
        sleep 1
      done
      ;;
    --reboot )
      wait_for_http
      reboot_modem
      wait_for_link
      ;;
    --setup )
      wait_for_http

#      log_rpc update /parameters/WWW/SATELLITE_LINK/RXFrequency \
#                     '<RXFrequency type="double">1687.625</RXFrequency>'
#
#      log_rpc update /parameters/WWW/SATELLITE_LINK/LNBFrequency \
#                     '<LNBFrequency type="double">10.6</LNBFrequency>'

      log_rpc update /parameters/WWW/SATELLITE_LINK/EnableLogin \
                     '<EnableLogin type="u8">1</EnableLogin>'

      log_rpc update /parameters/WWW/SATELLITE_LINK/EnableDebug \
                     '<EnableDebug type="u8">1</EnableDebug>'

      log_rpc commit '/*'

      ;;
    * )
      echo "Usage: $0 { --poll | --reboot | --setup | --debug }"
      exit 1
      ;;
  esac
done

if test "$*" = "" ; then
  if check_default_route && test_name_servers && test_web_servers ; then
    echo Internet connectivity test passed
  else
    echo Internet connectivity test failed
    date
    wait_for_http
    report_modem_status
  fi
fi
