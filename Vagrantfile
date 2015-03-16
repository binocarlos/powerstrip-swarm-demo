# -*- mode: ruby -*-
# vi: set ft=ruby :

# This requires Vagrant 1.6.2 or newer (earlier versions can't reliably
# configure the Fedora 20 network stack).
Vagrant.require_version ">= 1.6.2"

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

ENV['VAGRANT_DEFAULT_PROVIDER'] = 'virtualbox'

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
 
  #config.vm.box_url = "http://storage.googleapis.com/experiments-clusterhq/orchestration-demos/powerstrip-swarm-demo-v1.box"
  #config.vm.box = "powerstrip-swarm-demo-v1"

  if Vagrant.has_plugin?("vagrant-cachier")
    config.cache.scope = :box
  end

  config.vm.define "master" do |master|
    master.vm.network :private_network, :ip => "172.16.255.250"
    master.vm.hostname = "master"
    master.vm.provider "virtualbox" do |v|
      v.memory = 1024
    end
    master.vm.provision "shell", inline: <<SCRIPT
bash /vagrant/install.sh master 172.16.255.250 172.16.255.251:2375,172.16.255.252:2375
SCRIPT
  end

  config.vm.define "node1" do |node1|
    node1.vm.network :private_network, :ip => "172.16.255.251"
    node1.vm.hostname = "node1"
    node1.vm.provider "virtualbox" do |v|
      v.memory = 1024
    end
    node1.vm.provision "shell", inline: <<SCRIPT
bash /vagrant/install.sh minion 172.16.255.251 172.16.255.250
SCRIPT
  end

  config.vm.define "node2" do |node2|
    node2.vm.network :private_network, :ip => "172.16.255.252"
    node2.vm.hostname = "node2"
    node2.vm.provider "virtualbox" do |v|
      v.memory = 1024
    end
    node2.vm.provision "shell", inline: <<SCRIPT
bash /vagrant/install.sh minion 172.16.255.252 172.16.255.250
SCRIPT
  end
end
