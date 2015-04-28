#!/bin/bash

do-error() {
  echo "-------------------" >&2
  echo "ERROR!" >&2
  echo "$@" >&2
  exit 1
}

if [[ -f "/vagrant" ]]; then
  do-error "it looks like you are running the test from inside vagrant"
fi

datestring=$(date)
unixsecs=$(date +%s)
flockervolumename="testflocker$unixsecs"
swarmvolumename="testswarm$unixsecs"

echo "removing containers"
vagrant ssh master -c "DOCKER_HOST=localhost:2375 docker rm -f demo-server demo-api"

echo "running test of basic Flocker migration without swarm"

# this will test that the underlying flocker mechanism is working
# it runs an Ubuntu container on node1 that writes to a Flocker volume
# it then runs another Ubuntu container on node2 that loads the data from this volume

echo "pull busybox onto node1"
vagrant ssh node1 -c "sudo docker pull busybox"
echo "pull busybox onto node2"
vagrant ssh node2 -c "sudo docker pull busybox"

echo "writing data to node1 ($datestring)"
vagrant ssh node1 -c "sudo docker run --rm -v /flocker/$flockervolumename:/data busybox sh -c \"echo $datestring > /data/file.txt\""
echo "reading data from node2"
filecontent=`vagrant ssh node2 -c "sudo docker run --rm -v /flocker/$flockervolumename:/data busybox sh -c \"cat /data/file.txt\""`
if [[ $filecontent == *"$datestring"* ]]
then
  echo "Datestring: $datestring found!"
else
  do-error "The contents of the text file is not $datestring it is: $filecontent"
fi

echo "starting web server"
vagrant ssh master -c "DOCKER_HOST=localhost:2375 docker run -d \
  --name demo-server \
  -e constraint:storage==disk \
  -e WEAVE_CIDR=10.255.0.11/24 \
  -e API_IP=10.255.0.10 \
  -p 8080:80 \
  binocarlos/multi-http-demo-server:latest"

echo "starting db server"
vagrant ssh master -c "DOCKER_HOST=localhost:2375 docker run -d \
  --hostname disk \
  --name demo-api \
  -e constraint:storage==disk \
  -e WEAVE_CIDR=10.255.0.10/24 \
  -v /flocker/$swarmvolumename:/tmp \
  binocarlos/multi-http-demo-api:latest"

echo "loading result"
counter=$(curl -L -sS http://172.16.255.251:8080)
echo $counter
if [[ "$counter" == *"disk: 1"* ]]; then
  echo "$counter contains disk: 1"
else
  do-error "The contents of the counter is not disk: 1"
fi

counter=$(curl -L -sS http://172.16.255.251:8080)
echo $counter
if [[ "$counter" == *"disk: 2"* ]]; then
  echo "$counter contains disk: 2"
else
  do-error "The contents of the counter is not disk: 2"
fi

echo "stopping db server on node1"
vagrant ssh master -c "DOCKER_HOST=localhost:2375 docker rm -f demo-api"

sleep 10

echo "starting db server on node2"
vagrant ssh master -c "DOCKER_HOST=localhost:2375 docker run -d \
  --hostname ssd \
  --name demo-api \
  -e constraint:storage==ssd \
  -e WEAVE_CIDR=10.255.0.10/24 \
  -v /flocker/$swarmvolumename:/tmp \
  binocarlos/multi-http-demo-api:latest"

sleep 10

echo "loading result"

counter=$(curl -L -sS http://172.16.255.251:8080)
echo $counter
if [[ "$counter" == *"ssd: 3"* ]]; then
  echo "$counter contains ssd: 3"
else
  do-error "The contents of the counter is not ssd: 3"
fi

counter=$(curl -L -sS http://172.16.255.251:8080)
echo $counter
if [[ "$counter" == *"ssd: 4"* ]]; then
  echo "$counter contains ssd: 4"
else
  do-error "The contents of the counter is not ssd: 4"
fi

echo "all tests were succesful"
exit 0




