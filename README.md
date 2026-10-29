# amqpcat

netcat for AMQP. CLI tool to publish to and consume from AMQP servers.

## Installation

Using snap:

```
snap install amqpcat
```

Using Homebrew in OS X:

```
brew install cloudamqp/cloudamqp/amqpcat
```

Using Docker/Podman:

```
docker run -it cloudamqp/amqpcat
```

From source:

```
brew install crystal # os x
snap install crystal # linux/ubuntu

git clone https://github.com/cloudamqp/amqpcat.git
cd amqpcat
shards build --release --production
```

There are more [Crystal installation alternatives](https://crystal-lang.org/install/).

## Usage

```
Usage: amqpcat [arguments]
    -P, --producer                   Producer mode, reading from STDIN, each line is a new message
    -C, --consumer                   Consume mode, message bodies are written to STDOUT
    -u URI, --uri=URI                URI to AMQP servera
    -d DIR, --dir=DIR                Directory to dump messages info when consuming
    -e EXCHANGE, --exchange=EXCHANGE Exchange
    -r ROUTINGKEY, --routing-key=KEY Routing key when publishing
    -q QUEUE, --queue=QUEUE          Queue to consume from
    -f FORMAT, --format=FORMAT       Format string (default "%s\n")
                     %e: Exchange name
                     %r: Routing key
                     %s: Body, as string
                     \n: Newline
                     \t: Tab
    -v, --version                    Display version
    -h, --help                       Show this help message
```

For AMQP 1.0, see the separate [`amqpcat10`](#amqp-10) command below.

## Examples

Send messages to a queue named `test`:

```sh
echo Hello World | amqpcat --producer --uri=$CLOUDAMQP_URL --queue test
```

Consume from the queue named `test`:

```sh
amqpcat --consumer --uri=$CLOUDAMQP_URL --queue test
```

Consume from the queue named `files`, dumping each message into a given
directory, instead of STDOUT, deriving the filename from the message
properties, or timestamp if no properties are set:

```sh
amqpcat --consumer --uri=$CLOUDAMQP_URL --queue files --dir /tmp/miaow/
```

With a temporary queue, consume messages sent to the exchange amq.topic with the routing key 'hello.world':

```sh
amqpcat --consumer --uri=$CLOUDAMQP_URL --exchange amq.topic --routing-key hello.world
```

Consume from the queue named `test`, format the output as CSV and pipe to file:
```sh
amqpcat --consumer --uri=$CLOUDAMQP_URL --queue test --format "%e,%r,"%s"\n | tee messages.csv
```

Publish messages from syslog to the exchange 'syslog' topic with the hostname as routing key
```sh
tail -f /var/log/syslog | amqpcat --producer --uri=$CLOUDAMQP_URL --exchange syslog --routing-key $HOSTNAME
```

Consume, parse and extract data from json messages:
```sh
amqpcat --consumer --queue json | jq .property
```

### AMQP 1.0

AMQP 1.0 is different enough from 0-9-1 (no exchanges/queues to declare,
links instead of channels, no RPC/stream semantics) that it gets its own
command, `amqpcat10`, instead of a flag on `amqpcat`.

The same `-e`/`-r`/`-q` options are reused to build a link address,
following RabbitMQ/LavinMQ's address v2 scheme: `-q test` addresses
`/queues/test`, and `-e my-exchange -r my-key` addresses
`/exchanges/my-exchange/my-key`.

```sh
echo Hello World | amqpcat10 --producer --uri=$CLOUDAMQP_URL --queue test
amqpcat10 --consumer --uri=$CLOUDAMQP_URL --queue test
```

If `-e`/`-r`/`-q` are all left out, the URI's path is tried as an address
v2 path directly, so a URL that already names the queue or exchange works
on its own:

```sh
echo Hello World | amqpcat10 --producer --uri amqp://host/queues/test
```

(`-e`/`-r`/`-q`, when given, always win -- the URI's path is then used as
the vhost instead, as usual.)

Since the URI's path can't be both the vhost and the address at once, use
`--vhost` to name a non-default vhost while still addressing straight off
the URI's path:

```sh
amqpcat10 --consumer --uri amqp://host/queues/test --vhost my-vhost
```

AMQP 1.0 has no topology frames, so the queue or exchange must already
exist on the broker -- `amqpcat10` never declares it. Consuming via an
exchange/routing-key binding isn't supported, only from a queue (`-q`).
RPC mode and stream offsets aren't supported either, so `amqpcat10` has
no `-R` or `-o` options.

## Development

amqpcat is built with [Crystal](https://crystal-lang.org/)

## Contributing

1. Fork it (<https://github.com/cloudamqp/amqpcat/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Carl Hörberg](https://github.com/carlhoerberg) - creator and maintainer
