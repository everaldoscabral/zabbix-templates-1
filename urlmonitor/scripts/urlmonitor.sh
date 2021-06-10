#!/bin/bash
## Zabbix Agent URL Monitoring with automatic discovery and check script for X509/SSL/HTTPS certificates
## author: Ugo Viti <ugo.viti@initzero.it>
## version: 20210610

## example input CSV file used by CVS to JSON zabbix discovery parser
# www.initzero.it
# www.wearequantico.it
# www.otherdomain.fqdn:8080
# https://www.amazon.it:443/gp/bestsellers/?ref_=nav_em_cs_bestsellers_0_1_1_2


## example of JSON input file interpretated by Zabbix
# {
#   "data":
#   [
#    { "{#SCHEMA}":"https", "{#HOST}":"www.initzero.it", "{#PORT}":"443", "{#PATH}":"" },
#    { "{#SCHEMA}":"https", "{#HOST}":"www.wearequantico.it", "{#PORT}":"443", "{#PATH}":"" },
#    { "{#SCHEMA}":"http", "{#HOST}":"example.com", "{#PORT}":"8080", "{#PATH}":"" },
#   ]
# }

cmd="$1"
shift
args="$@"

[ -z "$cmd" ] && echo "ERROR: missing command... exiting" && exit 1
[ -z "$args" ] && echo "ERROR: missing args... exiting" && exit 1


#
# URI parsing function
#
# The function creates global variables with the parsed results.
# It returns 0 if parsing was successful or non-zero otherwise.
#
# [schema://][user[:password]@]host[:port][/path][?[arg1=val1]...][#fragment]
#
# thanks to: https://wp.vpalos.com/537/uri-parsing-using-bash-built-in-features/
function uri_parser() {
    # uri capture
    uri="$@"

    # safe escaping
    uri="${uri//\`/%60}"
    uri="${uri//\"/%22}"

    # top level parsing
    pattern='^(([a-z]{3,5}):\/\/)?((([^:\/]+)(:([^@\/]*))?@)?([^:\/?]+)(:([0-9]+))?)(\/[^?]*)?(\?[^#]*)?(#.*)?$'
    [[ "$uri" =~ $pattern ]] || return 1;

    # component extraction
    uri=${BASH_REMATCH[0]}
    uri_schema=${BASH_REMATCH[2]}
    uri_address=${BASH_REMATCH[3]}
    uri_username=${BASH_REMATCH[5]}
    uri_password=${BASH_REMATCH[7]}
    uri_host=${BASH_REMATCH[8]}
    uri_port=${BASH_REMATCH[10]}
    uri_path=${BASH_REMATCH[11]}
    uri_query=${BASH_REMATCH[12]}
    uri_fragment=${BASH_REMATCH[13]}

    # path parsing
    count=0
    path="$uri_path"
    pattern='^/+([^/]+)'
    while [[ $path =~ $pattern ]]; do
        eval "uri_parts[$count]=\"${BASH_REMATCH[1]}\""
        path="${path:${#BASH_REMATCH[0]}}"
        let count++
    done

    # query parsing
    count=0
    query="$uri_query"
    pattern='^[?&]+([^= ]+)(=([^&]*))?'
    while [[ $query =~ $pattern ]]; do
        eval "uri_args[$count]=\"${BASH_REMATCH[1]}\""
        eval "uri_arg_${BASH_REMATCH[1]}=\"${BASH_REMATCH[3]}\""
        query="${query:${#BASH_REMATCH[0]}}"
        let count++
    done

    # return success
    return 0
}

# print CSV formatted list removing blank and commented lines

parseCSVURLs() {
  csv="$args"
  uri_parser "$csv"
  
  if [ -z "$uri_schema" ]; then
      cat "$csv" | sed -e '/^#/d' -e '/^$/d' -e '/^{#/d'
    else
      curl -s "$csv" | sed -e '/^#/d' -e '/^$/d' -e '/^{#/d'
  fi
}

detectURLParts() {
  uri_parser "$URL"
  
  # default to https
  if [ -z "$uri_schema" ]; then
      uri_schema="https"
  fi

  if [ -z "$uri_port" ]; then
    case $uri_schema in
      http) uri_port="80" ;;
      *)    uri_port="443" ;;
    esac
  fi
  
  SCHEMA="$uri_schema"
  HOST="$uri_host"
  PORT="$uri_port"
  PATH="${uri_path}${uri_query}${uri_fragment}"
}

printSSLHosts() {
  parseCSVURLs | while read URL; do
    detectURLParts
    echo "    { \"{#HOST}\":\"${HOST}\", \"{#PORT}\":\"${PORT}\" },"
  done
}

printWEBHosts() {
  parseCSVURLs | while read URL; do
    detectURLParts
    echo "    { \"{#URL}\":\"${SCHEMA}://${HOST}:${PORT}${PATH}\" },"
  done
}

## discovery rules
discoverySSLHosts() {
  url="$1"

  echo "{
\"data\":
  ["
  printSSLHosts | sed 'H;1h;$!d;x;s/\(.*\),/\1/'
  echo "  ]
}"
}

discoveryWEBHosts() {
  url="$1"

  echo "{
\"data\":
  ["
  printWEBHosts | sed 'H;1h;$!d;x;s/\(.*\),/\1/'
  echo "  ]
}"
}


# output in datetime format
getSSLExpireDate() {
  [ -z "$HOST" ] && echo "getSSLExpireDate: SSL host address not specified... exiting" && exit 1
  [ -z "$PORT" ] && echo "getSSLExpireDate: SSL port number not specified... exiting" && exit 1
  timeout 5 openssl s_client -host "$HOST" -port $PORT -servername "$HOST" -showcerts </dev/null 2>/dev/null | sed -n '/BEGIN CERTIFICATE/,/END CERT/p' | openssl x509 -text 2>/dev/null | sed -n 's/ *Not After : *//p' 
}

# output in unixtime format
ssl.timeLeft() {
  HOST="$1"
  shift
  PORT="$1"
  shift
  sslExpireDate=$(getSSLExpireDate)
  if [ ! -z "$sslExpireDate" ]; then
    echo $(($(date '+%s' --date "$sslExpireDate") - $(date '+%s')))
   else
    echo 0
    return 1
  fi
}

# output in unixtime format
ssl.timeExpire() {
  HOST="$1"
  shift
  PORT="$1"
  shift
  sslExpireDate=$(getSSLExpireDate)
  if [ ! -z "$sslExpireDate" ]; then
    date '+%s' --date "$sslExpireDate"
   else
    echo 0
    return 1
  fi
}

# output in unixtime format
url.monitor() {
  URL="$1"
  shift
  HOST="$1"
  shift
  curl -s --connect-timeout 30 "$URL"
}

# execute the given command
#set -x
$cmd $args
exit $?
