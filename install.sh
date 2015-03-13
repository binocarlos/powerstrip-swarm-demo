#!/bin/bash

export FLOCKER_CONTROL_PORT=${FLOCKER_CONTROL_PORT:=80}
export INCLUDE_WEAVE=${INCLUDE_WEAVE:=y}
export MASTER_IP=${MASTER_IP:=172.16.255.250}
export MINION_IP=${MINION_IP:=172.16.255.251}

# supported distributions: "ubuntu", "redhat" (means centos/fedora)
export DISTRO=${DISTRO:="ubuntu"}

export FLOCKER_ZFS_AGENT=`which flocker-zfs-agent`
export FLOCKER_CONTROL=`which flocker-control`
export DOCKER=`which docker`
export BASH=`which bash`

# on subsequent vagrant ups - vagrant has not mounted /vagrant/install.sh
# so we copy it into place
cmd-copy-vagrant-dir() {
  cp -r /vagrant /srv/vagrant
}

cmd-setup-ssh-keys() {
  echo "copying keys to /root/.ssh"
  cp /vagrant/insecure_private_key /root/.ssh/id_rsa
  chmod 600 /root/.ssh/id_rsa
  chown root:root /root/.ssh/id_rsa
  cat /vagrant/insecure_public_key >> /root/.ssh/authorized_keys
  echo "copying keys to /home/vagrant/.ssh"
  cp /vagrant/insecure_private_key /home/vagrant/.ssh/id_rsa
  chmod 600 /home/vagrant/.ssh/id_rsa
  chown vagrant:vagrant /home/vagrant/.ssh/id_rsa
  cat /vagrant/insecure_public_key >> /home/vagrant/.ssh/authorized_keys
}

# extract the current zfs-agent uuid from the volume.json - sed sed sed!
cmd-get-flocker-uuid() {
  if [[ ! -f /etc/flocker/volume.json ]]; then
    >&2 echo "/etc/flocker/volume.json NOT FOUND";
    exit 1;
  fi
  # XXX should use actual json parser!
  cat /etc/flocker/volume.json | sed 's/.*"uuid": "//' | sed 's/"}//'
}

cmd-setup-zfs-pool() {
  zfs_pool_name="flocker"

  if [[ -b /dev/xvdb ]]; then
      echo "Detected EBS environment, setting up real zpool..."
      umount /mnt # this is where xvdb is mounted by default
      zpool create $zfs_pool_name /dev/xvdb
  elif [[ ! -b /dev/sdb ]]; then
      echo "Setting up a toy zpool..."
      truncate -s 10G /$zfs_pool_name-datafile
      zpool create $zfs_pool_name /$zfs_pool_name-datafile
  fi

}

# wait until the named file exists
cmd-wait-for-file() {
  while [[ ! -f $1 ]]
  do
    echo "wait for file $1" && sleep 1
  done
}

# configure docker to listen on a different unix socket and make sure selinux is not turned on
cmd-configure-docker() {

  local hostlabel=$1;
  shift;

  if [[ "$DISTRO" == "redhat" ]]; then
    /usr/sbin/setenforce 0
  fi

  echo "configuring docker to listen on unix:///var/run/docker.real.sock";

  if [[ "$DISTRO" == "redhat" ]]; then
    # docker itself listens on docker.real.sock and powerstrip listens on docker.sock
    cat << EOF > /etc/sysconfig/docker-network
DOCKER_NETWORK_OPTIONS=-H unix:///var/run/docker.real.sock --dns 8.8.8.8 --dns 8.8.4.4 --label node=$hostlabel
EOF

    # the key here is removing the selinux=yes option from docker
    cat << EOF > /etc/sysconfig/docker
OPTIONS=''
DOCKER_CERT_PATH=/etc/docker
TMPDIR=/var/tmp
EOF
  fi

  if [[ "$DISTRO" == "ubuntu" ]]; then
    #apt-get -y install linux-image-extra-$(uname -r)
    #  -s aufs
    cat << EOF > /etc/default/docker
DOCKER_OPTS="-H unix:///var/run/docker.real.sock --dns 8.8.8.8 --dns 8.8.4.4 --label node=$hostlabel"
EOF
  fi

  cmd-restart-docker
  rm -f /var/run/docker.sock
}

cmd-enable-system-service() {
  if [[ "$DISTRO" == "redhat" ]]; then
    # create a link for the named systemd unit so it starts at boot
    ln -sf /etc/systemd/system/$1.service /etc/systemd/system/multi-user.target.wants/$1.service
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    # re-read the config files on disk (supervisorctl always has everything enabled)
    supervisorctl update
  fi
}

cmd-reload-process-supervisor() {
  if [[ "$DISTRO" == "ubuntu" ]]; then
    supervisorctl update
  fi
  if [[ "$DISTRO" == "redhat" ]]; then
    systemctl daemon-reload
  fi
}

cmd-start-system-service() {
  if [[ "$DISTRO" == "ubuntu" ]]; then
    supervisorctl start $1
  fi
  if [[ "$DISTRO" == "redhat" ]]; then
    # systemd requires services to be enabled before they're started, but
    # supervisor enables services by default (?)
    systemctl enable $1.service
    systemctl start $1.service
  fi
}

cmd-stop-system-service() {
  if [[ "$DISTRO" == "ubuntu" ]]; then
    supervisorctl stop $1
  fi
  if [[ "$DISTRO" == "redhat" ]]; then
    systemctl stop $1.service
  fi
}

cmd-restart-docker() {
  if [[ "$DISTRO" == "ubuntu" ]]; then
    service docker restart
  fi
  if [[ "$DISTRO" == "redhat" ]]; then
    systemctl restart docker.service
  fi
}

# stop and remove a named container
cmd-docker-remove() {
  echo "remove container $1";
  DOCKER_HOST="unix:///var/run/docker.real.sock" $DOCKER stop $1 2>/dev/null || true
  DOCKER_HOST="unix:///var/run/docker.real.sock" $DOCKER rm $1 2>/dev/null || true
}

# docker pull a named container - this always runs before the docker socket
# gets reconfigured
cmd-docker-pull() {
  echo "pull image $1";
  $DOCKER pull $1
}

# configure powerstrip-flocker adapter
cmd-configure-adapter() {
  cmd-fetch-config-from-disk-if-present $@
  local cmd="/srv/vagrant/install.sh start-adapter $IP $CONTROLIP"
  local service="powerstrip-flocker"

  echo "configure powerstrip adapter - $1 $2";

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Powerstrip Flocker Adapter
After=docker.service
Requires=docker.service

[Service]
ExecStart=$BASH $cmd
ExecStop=$BASH /srv/vagrant/install.sh docker-remove $service

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$BASH $cmd
EOF
  # XXX there's no equivalent "ExecStop" command in supervisor...
  fi

  cmd-enable-system-service $service
}

# the actual boot command for the powerstrip adapter
# we run without -d so that process manager can manage the process properly
cmd-start-adapter() {
  cmd-fetch-config-from-disk-if-present $@
  cmd-docker-remove powerstrip-flocker
  local HOSTID=$(cmd-get-flocker-uuid)
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name powerstrip-flocker \
    --expose 80 \
    -e "MY_NETWORK_IDENTITY=$IP" \
    -e "FLOCKER_CONTROL_SERVICE_BASE_URL=http://$CONTROLIP:80/v1" \
    -e "MY_HOST_UUID=$HOSTID" \
    clusterhq/powerstrip-flocker:latest
}

# configure powerstrip-flocker adapter
cmd-configure-weave() {
  cmd-fetch-config-from-disk-if-present $@
  local cmd="/srv/vagrant/install.sh start-weave $IP $CONTROLIP"
  local service="powerstrip-weave"

  echo "configure weave adapter - $1 $2";

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Powerstrip Weave Adapter
After=docker.service
Requires=docker.service

[Service]
ExecStart=$BASH $cmd
ExecStop=$BASH /srv/vagrant/install.sh docker-remove $service

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$BASH $cmd
EOF
  # XXX there's no equivalent "ExecStop" command in supervisor...
  fi

  cmd-enable-system-service $service
}

# the actual boot command for the powerstrip-weave adapter
# we run without -d so that process manager can manage the process properly
cmd-start-weave() {
  cmd-fetch-config-from-disk-if-present $@
  local connectpeer="";

  if [[ "$IP" != "$CONTROLIP" ]]; then
    connectpeer="$CONTROLIP";
  fi
  cmd-docker-remove powerstrip-weave
  cmd-docker-remove weavewait
  cmd-docker-remove weave
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name powerstrip-weave \
    --expose 80 \
    -e DOCKER_SOCKET="/var/run/docker.real.sock" \
    -v /var/run/docker.real.sock:/var/run/docker.sock \
    binocarlos/powerstrip-weave launch $connectpeer
}

# configure socat to listen to 0.0.0.0:2375 -> /var/run/docker.sock
cmd-configure-tcpproxy() {

  local cmd="/srv/vagrant/install.sh start-tcpproxy"
  local service="powerstrip-tcpproxy"

  echo "configure tcp proxy";

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Powerstrip TCP Proxy
After=docker.service
Requires=docker.service

[Service]
ExecStart=$BASH $cmd

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$BASH $cmd
EOF
  # XXX there's no equivalent "ExecStop" command in supervisor...
  fi

  cmd-enable-system-service $service
}


# the actual boot command for the powerstrip-weave adapter
# we run without -d so that process manager can manage the process properly
cmd-start-tcpproxy() {
  socat TCP-LISTEN:2376,reuseaddr,fork UNIX-CLIENT:/var/run/docker.sock
}

# configure socat to listen to 0.0.0.0:2375 -> /var/run/docker.sock
cmd-configure-swarm() {
  local cmd="/srv/vagrant/install.sh start-swarm"
  local service="swarm"

  echo "configure swarm";

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Swarm
After=docker.service
Requires=docker.service

[Service]
ExecStart=$BASH $cmd

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$BASH $cmd
EOF
  # XXX there's no equivalent "ExecStop" command in supervisor...
  fi

  cmd-enable-system-service $service
}

# the actual boot command for the powerstrip-weave adapter
# we run without -d so that process manager can manage the process properly
cmd-start-swarm() {
  cmd-docker-remove swarm
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run --name swarm \
    -p 2375:2375 \
    swarm manage -H 0.0.0.0:2375 $MASTER_IP:2376,$MINION_IP:2376
}

cmd-configure-powerstrip() {
  local cmd="/srv/vagrant/install.sh start-powerstrip"
  local service="powerstrip"

  echo "configure $service";

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Powerstrip Server
After=powerstrip-flocker.service
Requires=powerstrip-flocker.service

[Service]
ExecStart=$BASH $cmd
ExecStop=$BASH /srv/vagrant/install.sh docker-remove $service

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$BASH $cmd
EOF
  fi

  cmd-enable-system-service $service
}


# the boot step for the powerstrip container - start without -d so process
# manager can manage the process
cmd-start-powerstrip() {
  rm -f /var/run/docker.sock
  cmd-docker-remove powerstrip

  if [[ -n $INCLUDE_WEAVE ]]; then
    DOCKER_HOST="unix:///var/run/docker.real.sock" \
    docker run --name powerstrip \
      -v /var/run:/host-var-run \
      -v /etc/powerstrip-demo/adapters.yml:/etc/powerstrip/adapters.yml \
      --link powerstrip-flocker:flocker \
      --link powerstrip-weave:weave \
      clusterhq/powerstrip:unix-socket
  else
    DOCKER_HOST="unix:///var/run/docker.real.sock" \
    docker run --name powerstrip \
      -v /var/run:/host-var-run \
      -v /etc/powerstrip-demo/adapters.yml:/etc/powerstrip/adapters.yml \
      --link powerstrip-flocker:flocker \
      clusterhq/powerstrip:unix-socket
  fi
}


cmd-weave() {
  DOCKER_HOST="unix:///var/run/docker.real.sock" \
  docker run -ti --rm \
    -e DOCKER_SOCKET="/var/run/docker.real.sock" \
    -v /var/run/docker.real.sock:/var/run/docker.sock \
    binocarlos/powerstrip-weave $@
}


# write out adapters.yml for powerstrip
cmd-powerstrip-config() {
  echo "write /etc/powerstrip-demo/adapters.yml";
  mkdir -p /etc/powerstrip-demo

  if [[ -n $INCLUDE_WEAVE ]]; then
  cat << EOF > /etc/powerstrip-demo/adapters.yml
version: 1
endpoints:
  "POST /*/containers/create":
    pre: [flocker,weave]
  "POST /*/containers/*/start":
    post: [weave]
adapters:
  flocker: http://flocker/flocker-adapter
  weave: http://weave/weave-adapter
EOF
  else
cat << EOF > /etc/powerstrip-demo/adapters.yml
version: 1
endpoints:
  "POST /*/containers/create":
    pre: [flocker]
adapters:
  flocker: http://flocker/flocker-adapter
EOF
  fi
}

# write systemd unit file for the zfs agent
cmd-flocker-zfs-agent() {
  local cmd="$BASH /srv/vagrant/install.sh block-start-flocker-zfs-agent $@"
  local service="flocker-zfs-agent"

  echo "configure $service";
  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Flocker ZFS Agent

[Service]
TimeoutStartSec=0
ExecStart=$cmd

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$cmd
EOF
  fi

  cmd-enable-system-service flocker-zfs-agent
}

# runner for the zfs agent
# we wait for there to be a docker socket by waiting for docker info
# we then wait for there to be a powerstrip container
cmd-block-start-flocker-zfs-agent() {
  # we're called from the outside, so figure out network identity etc
  cmd-fetch-config-from-disk-if-present $@
  echo "waiting for docker socket before starting flocker-zfs-agent";

  while ! (docker info \
        && sleep 1 && docker info && sleep 1 && docker info \
        && sleep 1 && docker info && sleep 1 && docker info \
        && sleep 1 && docker info); do echo "waiting for /var/run/docker.sock"; sleep 1; done;
  # TODO maaaaybe check for powerstrip container running here?
  $FLOCKER_ZFS_AGENT $IP $CONTROLIP
}


# configure control service with process manager
cmd-flocker-control() {
  local cmd="$FLOCKER_CONTROL -p $FLOCKER_CONTROL_PORT"
  local service="flocker-control"

  echo "configure $service"

  if [[ "$DISTRO" == "redhat" ]]; then
    cat << EOF > /etc/systemd/system/$service.service
[Unit]
Description=Flocker Control Service

[Service]
TimeoutStartSec=0
ExecStart=$cmd

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ "$DISTRO" == "ubuntu" ]]; then
    cat << EOF > /etc/supervisor/conf.d/$service.conf
[program:$service]
command=$cmd
EOF
  fi

  cmd-enable-system-service flocker-control
}

# generic controller for the powerstrip containers
cmd-powerstrip() {
  # write adapters.yml
  cmd-powerstrip-config

  # write unit files for powerstrip-flocker and powerstrip
  cmd-configure-adapter $@

  if [[ -n $INCLUDE_WEAVE ]]; then
    cmd-configure-weave $@
  fi

  cmd-configure-powerstrip

  # kick off services
  cmd-reload-process-supervisor
  cmd-start-system-service powerstrip-flocker

  if [[ -n $INCLUDE_WEAVE ]]; then
    cmd-start-system-service powerstrip-weave
  fi

  cmd-start-system-service powerstrip
  cmd-configure-tcpproxy $@
  cmd-start-system-service powerstrip-tcpproxy
}

# kick off the zfs-agent so it writes /etc/flocker/volume.json
# then kill it before starting the powerstrip-adapter (which requires the file)
cmd-setup-zfs-agent() {
  local hostlabel=$1;
  shift;
  cmd-flocker-zfs-agent $@

  # we need to start the zfs service so we have /etc/flocker/volume.json
  cmd-reload-process-supervisor
  cmd-start-system-service flocker-zfs-agent
  cmd-wait-for-file /etc/flocker/volume.json
  cmd-stop-system-service flocker-zfs-agent
  killall flocker-zfs-agent

  # setup docker on /var/run/docker.real.sock
  cmd-configure-docker $hostlabel
}

cmd-fetch-config-from-disk-if-present() {
  # $1 is <your_ip>, $2 is <control_service>
  if [[ -f /etc/flocker/my_address ]]; then
      IP=`cat /etc/flocker/my_address`
  else
      IP=$1
  fi
  if [[ -f /etc/flocker/master_address ]]; then
      CONTROLIP=`cat /etc/flocker/master_address`
  else
      CONTROLIP=$2
  fi
  if [[ -z "$CONTROLIP" ]]; then
    CONTROLIP="127.0.0.1";
  fi
}

cmd-init() {
  # nerf the ARP cache so the delay is minimal between assigning an IP to another container
  echo 5000 > /proc/sys/net/ipv4/neigh/default/base_reachable_time_ms
  
  # install packages
  apt-get install -y socat

  # make vagrant directory persistent
  cmd-copy-vagrant-dir

  cmd-setup-ssh-keys

  # setup the ZFS pool
  cmd-setup-zfs-pool

  cmd-fetch-config-from-disk-if-present $@

  # pull the images first
  cmd-docker-pull ubuntu:latest
  cmd-docker-pull clusterhq/powerstrip-flocker:latest
  cmd-docker-pull binocarlos/powerstrip-weave:latest
  cmd-docker-pull binocarlos/wait-for-weave:latest
  cmd-docker-pull zettio/weave:latest
  cmd-docker-pull zettio/weavetools:latest
  cmd-docker-pull zettio/weavedns:latest
  cmd-docker-pull clusterhq/powerstrip:unix-socket
  cmd-docker-pull binocarlos/swarmdemo-api:latest
  cmd-docker-pull binocarlos/swarmdemo-server:latest
  cmd-docker-pull swarm
}

cmd-master() {
  # common initialisation
  cmd-init

  # write unit files for both services
  cmd-flocker-control
  cmd-setup-zfs-agent master $@

  cmd-powerstrip $@

  # kick off systemctl
  cmd-reload-process-supervisor
  cmd-start-system-service flocker-control
  cmd-start-system-service flocker-zfs-agent

  cmd-configure-swarm $@
  cmd-start-system-service swarm
}

cmd-minion() {
  # common initialisation
  cmd-init

  cmd-setup-zfs-agent minion $@

  cmd-powerstrip $@

  cmd-reload-process-supervisor
  cmd-start-system-service flocker-zfs-agent
}

usage() {
cat <<EOF
Usage:
install.sh master <your_ip> <control_service>
install.sh minion <your_ip> <control_service>
install.sh flocker-zfs-agent
install.sh block-start-flocker-zfs-agent <your_ip> <control_service>
install.sh flocker-control
install.sh get-flocker-uuid
install.sh configure-docker
install.sh configure-powerstrip
install.sh configure-adapter
install.sh configure-weave
install.sh configure-tcpproxy
install.sh configure-swarm
install.sh start-adapter
install.sh start-powerstrip
install.sh start-weave
install.sh start-tcpproxy
install.sh start-swarm
install.sh weave-status
install.sh powerstrip-config
install.sh help
EOF
  exit 1
}

main() {
  case "$1" in
  master)                   shift; cmd-master $@;;
  minion)                   shift; cmd-minion $@;;
  flocker-zfs-agent)        shift; cmd-flocker-zfs-agent $@;;
  block-start-flocker-zfs-agent) shift; cmd-block-start-flocker-zfs-agent $@;;
  flocker-control)          shift; cmd-flocker-control $@;;
  get-flocker-uuid)         shift; cmd-get-flocker-uuid $@;;
  configure-docker)         shift; cmd-configure-docker $@;;
  configure-powerstrip)     shift; cmd-configure-powerstrip $@;;
  configure-adapter)        shift; cmd-configure-adapter $@;;
  configure-weave)          shift; cmd-configure-weave $@;;
  configure-tcpproxy)       shift; cmd-configure-tcpproxy $@;;
  configure-swarm)          shift; cmd-configure-swarm $@;;
  start-adapter)            shift; cmd-start-adapter $@;;
  start-powerstrip)         shift; cmd-start-powerstrip $@;;
  start-weave)              shift; cmd-start-weave $@;;
  start-tcpproxy)           shift; cmd-start-tcpproxy $@;;
  start-swarm)              shift; cmd-start-swarm $@;;
  weave)                    shift; cmd-weave $@;;
  powerstrip-config)        shift; cmd-powerstrip-config $@;;
  docker-remove)            shift; cmd-docker-remove $@;;
  *)                        usage $@;;
  esac
}

main "$@"
