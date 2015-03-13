.PHONY: build

build:
	vagrant destroy -f
	vagrant up
	vagrant ssh -c "sudo bash /vagrant/install.sh"
	#vagrant package