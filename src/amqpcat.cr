require "option_parser"
require "amqp-client"

class AMQPCat
  VERSION = {{ `git describe 2>/dev/null || shards version`.stringify.gsub(/(^v|\n)/, "") }}

  def initialize(uri : String)
    @client = AMQP::Client.new(uri)
  end

  def produce(exchange : String, routing_key : String)
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

  def consume(exchange_name : String?, routing_key : String?, queue_name : String?, format : String)
    exchange_name ||= ""
    routing_key ||= ""
    queue_name ||= ""
    loop do
      connection = @client.connect
      channel = connection.channel
      q =
        begin
          channel.queue(queue_name)
        rescue
          channel = connection.channel
          channel.queue(queue_name, passive: true)
        end
      unless exchange_name.empty? && routing_key.empty?
        q.bind(exchange_name, routing_key)
      end
      q.subscribe(block: true, no_ack: true) do |msg|
        format_output(STDOUT, format, msg)
      end
    rescue ex
      STDERR.puts ex.message
      sleep 2
    end
  end

  private def format_output(io, format_str, msg)
    io.sync = false
    match = false
    escape = false
    Char::Reader.new(format_str).each do |c|
      if c == '%'
        match = true
      elsif match
        case c
        when 's'
          io << msg.body_io
        when 'e'
          io << msg.exchange
        when 'r'
          io << msg.routing_key
        when '%'
          io << '%'
        else
          raise "Invalid substitution argument '%#{c}'"
        end
        match = false
      elsif c == '\\'
        escape = true
      elsif escape
        case c
        when 'n'
          io << '\n'
        when 't'
          io << '\t'
        else
          raise "Invalid escape character '\#{c}'"
        end
        escape = false
      else
        io << c
      end
    end
    io.flush
  end
end

uri = "amqp://localhost"
mode = nil
exchange = ""
queue = nil
routing_key = nil
format = "%s\n"

FORMAT_STRING_HELP = <<-HELP
Format string (default "%s\\n")
\t\t\t\t\t%e: Exchange name
\t\t\t\t\t%r: Routing key
\t\t\t\t\t%s: Body, as string
\t\t\t\t\t\\n: Newline
\t\t\t\t\t\\t: Tab
HELP

p = OptionParser.parse do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-P", "--producer", "Producer mode, reading from STDIN, each line is a new message") { mode = :producer }
  parser.on("-C", "--consumer", "Consume mode, message bodies are written to STDOUT") { mode = :consumer }
  parser.on("-u URI", "--uri=URI", "URI to AMQP server") { |v| uri = v }
  parser.on("-e EXCHANGE", "--exchange=EXCHANGE", "Exchange") { |v| exchange = v }
  parser.on("-r ROUTINGKEY", "--routing-key=KEY", "Routing key when publishing") { |v| routing_key = v }
  parser.on("-q QUEUE", "--queue=QUEUE", "Queue to consume from") { |v| queue = v }
  parser.on("-f FORMAT", "--format=FORMAT", FORMAT_STRING_HELP) { |v| format = v }
  parser.on("-h", "--help", "Show this help message") { |v| puts parser; exit 0 }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid argument."
    abort parser
  end
end

cat = AMQPCat.new(uri)
case mode
when :producer
  unless routing_key || queue
    STDERR.puts "Error: Missing routing key or queue argument."
    abort p
  end
  cat.produce(exchange, routing_key || queue || "")
when :consumer
  unless routing_key || queue
    STDERR.puts "Error: Missing routing key or queue argument."
    abort p
  end
  cat.consume(exchange, routing_key, queue, format)
else
  STDERR.puts "Error: Missing argument, --producer or --consumer required."
  abort p
end
