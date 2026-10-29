require "option_parser"
require "./amqpcat10"
require "./version"

uri = "amqp://localhost"
mode = :consumer
exchange = ""
queue : String? = nil
vhost : String? = nil
routing_key : String? = nil
format = "%s\n"
publish_confirm = false
output_dir : String? = nil
props = AMQ::Protocol::Properties.new(delivery_mode: 2_u8)

FORMAT_STRING_HELP = <<-HELP
Format string (default "%s\\n")
\t\t\t\t     %e: Exchange name
\t\t\t\t     %r: Routing key
\t\t\t\t     %t: Content type
\t\t\t\t     %s: Body, as string
\t\t\t\t     %h: Headers, as key=value
\t\t\t\t     \\n: Newline
\t\t\t\t     \\t: Tab
HELP

p = OptionParser.parse do |parser|
  parser.banner = <<-BANNER
  Usage: #{File.basename PROGRAM_NAME} [arguments]

  Speaks AMQP 1.0. The queue or exchange must already exist on the broker --
  amqpcat10 never declares topology. -e/-r/-q build a link address following
  RabbitMQ/LavinMQ's address v2 scheme: -q test addresses /queues/test, and
  -e my-exchange -r my-key addresses /exchanges/my-exchange/my-key. Consuming
  is only supported from a queue (-q), not an exchange binding.
  BANNER
  parser.on("-P", "--producer", "Producer mode, reading from STDIN, each line is a new message") { mode = :producer }
  parser.on("-C", "--consumer", "Consume mode, message bodies are written to STDOUT") { mode = :consumer }
  parser.on("-u URI", "--uri=URI", "URI to AMQP server") { |v| uri = v }
  parser.on("--vhost=VHOST", "Vhost (needed when the URI's path is used as a link address instead)") { |v| vhost = v }
  parser.on("-e EXCHANGE", "--exchange=EXCHANGE", "Exchange (default: '')") { |v| exchange = v }
  parser.on("-r ROUTINGKEY", "--routing-key=KEY", "Routing key when publishing") { |v| routing_key = v }
  parser.on("-q QUEUE", "--queue=QUEUE", "Queue to publish or consume from") { |v| queue = v }
  parser.on("-c", "--publish-confirm", "Confirm publishes") { publish_confirm = true }
  parser.on("-m VALUE", "--mode=VALUE", "Delivery mode, 1 = transient, 2 = persistent") do |v|
    props.delivery_mode = case v
                          when "1" then 1_u8
                          when "2" then 2_u8
                          else          abort "Error: delivery_mode must be 1 or 2, got: #{v.inspect}"
                          end
  end
  parser.on("-f FORMAT", "--format=FORMAT", FORMAT_STRING_HELP) { |v| format = v }
  parser.on("-d DIR", "--dir=DIR", "Directory to write messages to (as separate files)") { |v| output_dir = v }
  parser.on("--content-type=TYPE", "Content type header") { |v| props.content_type = v }
  parser.on("--content-encoding=ENC", "Content encoding header") { |v| props.content_encoding = v }
  parser.on("--priority=LEVEL", "Priority header") { |v| props.priority = v.to_u8? || abort "Priority must be between 0 and 255" }
  parser.on("--expiration=TIME", "Expiration header (ms before msg is dead lettered)") { |v| props.expiration = v }
  parser.on("-z", "Exit on connection") { mode = :connect }
  parser.on("-v", "--version", "Display version") { puts AMQPCat::VERSION; exit 0 }
  parser.on("-h", "--help", "Show this help message") { puts parser; exit 0 }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid argument."
    abort parser
  end
end

cat = AMQPCat10.new(uri)

case mode
when :producer
  unless exchange || queue
    STDERR.puts "Error: Missing exchange or queue argument."
    abort p
  end
  cat.produce(exchange, routing_key || queue || "", publish_confirm, props, vhost)
when :consumer
  cat.consume(exchange, routing_key, queue, format, output_dir, vhost)
when :connect
  cat.connect(vhost)
  exit 0
end
