#!/bin/bash

do-error() {
  echo $1 >&2
  exit 1
}

if [[ -f "/vagrant" ]]; then
  do-error "it looks like you are running the test from inside vagrant"
fi

vagrant ssh node1 -c "sudo docker run --rm -v /flocker/tester1:/data ubuntu sh -c \"echo hello > /data/file.txt\""
vagrant ssh node2 -c "sudo docker run --rm -v /flocker/tester1:/data ubuntu sh -c \"cat /data/file.txt\""