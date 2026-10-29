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
                     %l: Latency in µs (needs a stamped message)
                     \n: Newline
                     \t: Tab
        --timestamp                  Producer: stamp messages with send time (x-sent-at header)
        --perftest-compat            Stamp/read send time as a 12 byte body prefix (PerfTest/omq compatible)
        --stats [SECS]               Print msg rate, latency and confirm latency to STDERR every SECS (default 1)
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

## Measuring latency

Producers stamp each message with the wall-clock send time, and consumers
compute `now - sent` on delivery. Publisher confirm latency (`-c`) is measured
per message on the producer.

```sh
# producer, stamps the x-sent-at header and prints confirm latency every second
yes hello | amqpcat -P -q test -c --timestamp --stats

# consumer, prints min/p50/p95/p99/max latency every second
amqpcat -C -q test --stats > /dev/null

# per message latency in µs
amqpcat -C -q test -f '%l\n'
```

Use `--perftest-compat` on both sides to put the timestamp in a 12 byte body
prefix (4 byte sequence number + 8 byte big endian timestamp), as RabbitMQ
PerfTest and [omq](https://github.com/rabbitmq/omq) do, so that amqpcat can
consume their messages and vice versa. Note that PerfTest needs `--use-millis`
for its timestamps to be comparable across processes.

Latency uses wall-clock time, so across hosts the numbers are only as accurate
as the clock synchronisation. Because `-c` waits for each confirm before
publishing the next message, the producer rate is bounded by the confirm round
trip.
