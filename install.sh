#!/bin/bash

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# install swarm on the master
# the actual boot command for the powerstrip-weave adapter
# we run without -d so that process manager can manage the process properly
cmd-swarm() {
  . /srv/powerstrip-base-install/ubuntu/lib.sh
  powerstrip-base-install-stop-container swarm
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name swarm \
    -p 2375:2375 \
    swarm manage -H 0.0.0.0:2375 $MASTER_IP:2376,$MINION_IP:2376
}


# install the tcp tunnel on the minions
# wait for the powerstrip container to start because it will produce the docker.sock
cmd-tcptunnel() {
  . /srv/powerstrip-base-install/ubuntu/lib.sh
  powerstrip-base-install-wait-for-container powerstrip
  socat TCP-LISTEN:2376,reuseaddr,fork UNIX-CLIENT:/var/run/docker.sock
}

write-service() {
  local service="$1";

  cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=bash /srv/install.sh $service
EOF
}

# basic setup such as copy this script to /srv
init() {
  cp -f /home/vagrant/install.sh /srv/install.sh
  echo "copying keys to /root/.ssh"
  cp /vagrant/insecure_private_key /root/.ssh/id_rsa
  chmod 600 /root/.ssh/id_rsa
  chown root:root /root/.ssh/id_rsa
  cat /vagrant/insecure_public_key >> /root/.ssh/authorized_keys
}

# here we build ontop of powerstrip-base-install and get swarm working on top
# the master expects the file /etc/flocker/swarm_addresses to be present
cmd-master() {
  local myaddress="$1";
  local swarmips="$2";
  mkdir -p /etc/flocker
  echo $myaddress > /etc/flocker/my_address
  echo $myadderss > /etc/flocker/master_address
  echo $swarmips > /etc/flocker/swarmips

  init

  . /srv/powerstrip-base-install/ubuntu/lib.sh
  bash /srv/powerstrip-base-install/ubuntu/install.sh pullimages master
  powerstrip-base-install-pullimage swarm
  activate-service flocker-control
  write-service swarm
}

# /etc/flocker/my_address
# /etc/flocker/master_address - master address
cmd-minion() {
  local myaddress="$1";
  local masteraddress="$2";
  mkdir -p /etc/flocker
  echo $myaddress > /etc/flocker/my_address
  echo $masteraddress > /etc/flocker/master_address

  init

  bash /srv/powerstrip-base-install/ubuntu/install.sh pullimages minion
}

usage() {
cat <<EOF
Usage:
install.sh master
install.sh minion
install.sh tcptunnel
install.sh swarm
install.sh help
EOF
  exit 1
}

main() {
  case "$1" in
  master)                   shift; cmd-master $@;;
  minion)                   shift; cmd-minion $@;;
  tcptunnel)                shift; cmd-tcptunnel $@;;
  swarm)                    shift; cmd-swarm $@;;
  *)                        usage $@;;
  esac
}

main "$@"