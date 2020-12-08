# amqpcat

netcat for AMQP. CLI tool to publish to and consume from AMQP servers.

## Installation

Using snap:

```
snap install amqpcat
```

Using Homebrew in OS X:

```
brew install cloudamqp/amqpcat
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
    -u URI, --uri=URI                URI to AMQP server
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

## Examples

Send messages to a queue named `test`:

```sh
echo Hello World | amqpcat --producer --uri=$CLOUDAMQP_URL --queue test
```

Consume from the queue named `test`:

```sh
amqpcat --consumer --uri=$CLOUDAMQP_URL --queue test
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
