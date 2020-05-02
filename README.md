# amqpcat

netcat for AMQP. CLI tool to publish to and consume from AMQP servers.

## Installation

Linux:

```
snap install amqpcat
```

Mac:

```
brew install amqpcat
```

From source:

```
shards install
shards build
```

## Usage

```
Usage: amqpcat [arguments]
    -P, --producer                   Producer mode, reading from STDIN, each line is a new message
    -C, --consumer                   Consume mode, message bodies are written to STDOUT
    -u URI, --uri=URI                URI to AMQP server
    -e EXCHANGE, --exchange=EXCHANGE Exchange
    -r ROUTINGKEY, --routing-key=KEY Routing key when publishing
    -q QUEUE, --queue=QUEUE          Queue to consume from
    -h, --help                       Show this help message
```

## Development

amqpcat is built in [Crystal](https://crystal-lang.org/)

## Contributing

1. Fork it (<https://github.com/cloudamqp/amqpcat/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Carl Hörberg](https://github.com/carlhoerberg) - creator and maintainer
