# powerstrip-swarm-demo

A demo of [powerstrip-flocker](https://github.com/clusterhq/powerstrip-flocker) and [powerstrip-weave](https://github.com/binocarlos/powerstrip-weave) working with [swarm](https://github.com/docker/swarm)

## install

First you need to install:

 * [virtualbox](https://www.virtualbox.org/wiki/Downloads)
 * [vagrant](http://www.vagrantup.com/downloads.html)

## run

To run the demo:

```bash
$ vagrant up
$ vagrant ssh master
$ bash /vagrant/run.sh demo
```

## about

This demo consists of 3 servers - a master and 2 nodes.

The master runs the swarm deamon and the flocker control server - the 2 nodes each run powerstrip and the 2 powerstrip adapters (for flocker and weave).

```
          docker client

                |

           swarm deamon
          flocker-control

           /          \

       node1          node2
       disk            SSD

         |              |

    powerstrip       powerstrip
     flocker          flocker
      weave            weave

        |               |

      docker          docker

```

We run a database and a HTTP server on node1.  We then decide to upgrade our database container to run on a server that has an SSD.

The IP address to connect to the database is hardcoded - when we move the database container we are migrating the IP address AND the data!

#### Initial Layout:

 * NODE1 (disk)
  * HTTP server
  * Database server (10.255.0.10 + /flocker/data)

 * NODE2 (SSD)

#### Final Layout:

 * NODE1 (disk)
  * HTTP server

 * NODE2 (SSD)
  * Database server (10.255.0.10 + /flocker/data)

## conclusion

We have moved both an IP address and a data volume across hosts using nothing more than the docker client!