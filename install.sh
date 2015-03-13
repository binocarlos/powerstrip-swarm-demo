#!/bin/bash

# here we build ontop of powerstrip-base-install and get swarm working on top
# the master expects the file /etc/flocker/swarm_addresses to be present
cmd-master() {

}

# /etc/flocker/my_address
# /etc/flocker/master_address - master address
cmd-minion() {

}

usage() {
cat <<EOF
Usage:
install.sh master
install.sh minion
install.sh help
EOF
  exit 1
}

main() {
  case "$1" in
  master)                   shift; cmd-master $@;;
  minion)                   shift; cmd-minion $@;;
  *)                        usage $@;;
  esac
}

main "$@"