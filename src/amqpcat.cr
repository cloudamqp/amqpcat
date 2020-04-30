require "option_parser"
require "amqp-client"

class AMQPCat
  VERSION = {{ `git describe 2>/dev/null || shards version`.chomp.stringify }}

  def initialize(@uri : String)
    @client = AMQP::Client.new(@uri)
  end

  def produce(exchange, routing_key)
    loop do
      connection = @client.connect
      channel = connection.channel
      props = AMQP::Client::Properties.new(delivery_mode: 2_u8)
      while line = STDIN.gets
        channel.basic_publish line, exchange, routing_key, props: props
      end
      break
    rescue ex
      STDERR.puts ex.message
      sleep 2
    end
  end

  def consume(queue_name)
    loop do
      connection = @client.connect
      channel = connection.channel
      q =
        begin
          channel.queue(queue_name, passive: true)
        rescue
          channel = connection.channel
          channel.queue(queue_name)
        end
      q.subscribe(block: true, no_ack: true) do |msg|
        STDOUT.puts msg.body_io
      end
    rescue ex
      STDERR.puts ex.message
      sleep 2
    end
  end
end

uri = "amqp://localhost"
mode = nil
exchange = ""
queue = nil
routing_key = nil
p = OptionParser.parse do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-u URI", "--uri=URI", "URI to AMQP server") { |v| uri = v }
  parser.on("-P", "--producer", "Producer mode, reading from STDIN, each line is a new message") { mode = :producer }
  parser.on("-C", "--consumer", "Consume mode, message bodies are written to STDOUT") { mode = :consumer }
  parser.on("-q QUEUE", "--queue=QUEUE", "Queue to consume from") { |v| queue = v }
  parser.on("-e EXCHANGE", "--exchange=EXCHANGE", "Exchange") { |v| exchange = v }
  parser.on("-r ROUTING_KEY", "--routing-key=KEY", "Routing key when publishing") { |v| routing_key = v }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    abort parser
  end
end

cat = AMQPCat.new(uri)
case mode
when :producer
  unless routing_key || queue
    STDERR.puts "Error: Missing routing key or queue argument"
    abort p
  end
  cat.produce(exchange, routing_key || queue || "")
when :consumer
  unless queue
    STDERR.puts "Error: Missing queue argument"
    abort p
  end
  cat.consume(queue.to_s)
else
  STDERR.puts "Error: Missing mode argument"
  abort p
end
