#!/bin/bash

do-error() {
  echo "$@" >&2
  exit 1
}

if [[ -f "/vagrant" ]]; then
  do-error "it looks like you are running the test from inside vagrant"
fi

# this will test that the underlying flocker mechanism is working
# it runs an Ubuntu container on node1 that writes to a Flocker volume
# it then runs another Ubuntu container on node2 that loads the data from this volume
vagrant ssh node1 -c "sudo docker run --rm -v /flocker/tester1:/data ubuntu sh -c \"echo hello > /data/file.txt\""
filecontent=$(vagrant ssh node2 -c "sudo docker run --rm -v /flocker/tester1:/data ubuntu sh -c \"cat /data/file.txt\"")

if [[ "$filecontent" != "hello" ]]; then
  do-error "The contents of the text file is not apple"
fi

