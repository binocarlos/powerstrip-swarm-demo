#!/bin/bash

export API_IP=${API_IP:=10.255.0.10}
export SERVER_IP=${SERVER_IP:=10.255.0.11}
export DOCKER_HOST=${DOCKER_HOST:=tcp://127.0.0.1:2375}
export HTTP_IP=${HTTP_IP:=172.16.255.251}

cmd-start-api() {
  local disktype="$1";

  if [[ -z $disktype ]]; then
    >&2 echo "disktype must be passed to start-api"
    exit 1
  fi
  local dockerruncmd="";
  read -d '' dockerruncmd << EOF
docker run -d \
  --hostname $disktype \
  --name demo-api \
  -e constraint:storage==$disktype \
  -e WEAVE_CIDR=$API_IP/24 \
  -v /flocker/data1:/tmp \
  binocarlos/multi-http-demo-api:latest
EOF

  echo $dockerruncmd;
  eval $dockerruncmd;
}

cmd-stop-api() {
  docker rm -f demo-api
}

cmd-start-server() {
  local dockerruncmd="";
  read -d '' dockerruncmd << EOF
docker run -d \
  --name demo-server \
  -e constraint:storage==disk \
  -e WEAVE_CIDR=$SERVER_IP/24 \
  -e API_IP=$API_IP \
  -p 8080:80 \
  binocarlos/multi-http-demo-server:latest
EOF
  
  echo $dockerruncmd;
  eval $dockerruncmd;
}

cmd-stop-server() {
  docker rm -f demo-server
}

cmd-hit-http(){
  curl -L http://$HTTP_IP:8080
}

cmd-loop-http() {
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
  cmd-hit-http
}

usage() {
cat <<EOF
Usage:
run.sh start-api
run.sh stop-api
run.sh start-server
run.sh stop-server
run.sh hit-http
run.sh loop-http
run.sh runthrough
run.sh ps
run.sh help
EOF
  exit 1
}

cmd-demo() {
  echo "Starting Database On DISK";
  cmd-start-api disk
  echo "Starting HTTP Server On NODE1"
  cmd-start-server
  echo "Wait 2 seconds"
  sleep 2
  echo "Show Info"
  info
  echo "Show Containers"
  ps
  echo "Hitting HTTP Server"
  cmd-loop-http
  echo "Stop Database"
  cmd stop-server
  echo "Start Database on SSD"
  cmd-start-api ssd
  echo "Wait 2 seconds"
  sleep 2
  echo "Show Info"
  info
  echo "Show Containers"
  ps
  echo "Hitting HTTP Server"
  cmd-loop-http

}

cmd-ps() {
  docker ps -a
}

cmd-info() {
  docker info
}

main() {
  case "$1" in
  start-api)             shift; cmd-start-api $@;;
  stop-api)              shift; cmd-stop-api $@;;
  start-server)          shift; cmd-start-server $@;;
  stop-server)           shift; cmd-stop-server $@;;
  hit-http)              shift; cmd-hit-http $@;;
  loop-http)             shift; cmd-loop-http $@;;
  demo)                  shift; cmd-demo $@;;
  ps)                    shift; cmd-ps $@;;
  info)                  shift; cmd-info $@;;
  *)                     usage $@;;
  esac
}

main "$@"
