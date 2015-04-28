.PHONY: test

test:
	vagrant up
	bash test.sh || (echo "bash test.sh failed $$?"; exit 1)
	vagrant destroy