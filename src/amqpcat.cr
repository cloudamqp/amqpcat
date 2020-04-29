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
      while line = STDIN.gets
        channel.basic_publish line, exchange, routing_key
      end
    rescue ex
      STDERR.puts "WARN: #{ex.message}"
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
      STDERR.puts "WARN: #{ex.message}"
    end
  end
end

uri = "amqp://localhost"
mode = nil
queue = nil
OptionParser.parse do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-u URI", "--uri=URI", "URI to AMQP server") { |v| uri = v }
  parser.on("-P", "--producer", "Producer mode") { mode = :producer }
  parser.on("-C", "--consumer", "Consume mode") { mode = :consumer }
  parser.on("-q QUEUE", "--queue=QUEUE", "Queue") { |v| queue = v }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    abort parser.to_s
  end
end

abort "Missing queue" unless queue
cat = AMQPCat.new(uri)
case mode
when :producer
  cat.produce("", queue.to_s)
when :consumer
  cat.consume(queue.to_s)
else
  abort "ERROR: invalid mode"
end
