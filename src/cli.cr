require "option_parser"
require "./amqpcat"
require "./version"

uri = "amqp://localhost"
mode = :consumer
exchange = ""
exchange_type = "direct"
queue : String? = nil
queue_type = "classic"
routing_key : String? = nil
format = "%s\n"
publish_confirm = false
offset = "next"

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
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [arguments]"
  parser.on("-P", "--producer", "Producer mode, reading from STDIN, each line is a new message") { mode = :producer }
  parser.on("-C", "--consumer", "Consume mode, message bodies are written to STDOUT") { mode = :consumer }
  parser.on("-u URI", "--uri=URI", "URI to AMQP server") { |v| uri = v }
  parser.on("-e EXCHANGE", "--exchange=EXCHANGE", "Exchange (default: '')") { |v| exchange = v }
  parser.on("-t EXCHANGETYPE", "--exchange-type=TYPE", "Exchange type (default: direct)") { |v| exchange_type = v }
  parser.on("-r ROUTINGKEY", "--routing-key=KEY", "Routing key when publishing") { |v| routing_key = v }
  parser.on("-q QUEUE", "--queue=QUEUE", "Queue to consume from") { |v| queue = v }
  parser.on("", "--queue-type=QUEUE_TYPE", "Queue type (classic, quorum or stream)") { |v| queue_type = v }
  parser.on("-c", "--publish-confirm", "Confirm publishes") { publish_confirm = true }
  parser.on("-o OFFSET", "--offset OFFSET", "Stream queue: Offset to start reading from ") do |v|
    if %w[first next last].includes? v
      offset = v
    elsif /^\d/.match v
      offset = v.to_i
    else
      STDERR.puts "Error: Invalid offset, support \"first\", \"next\", \"last\" or offset."
      exit 1
    end
  end
  parser.on("-f FORMAT", "--format=FORMAT", FORMAT_STRING_HELP) { |v| format = v }
  parser.on("-v", "--version", "Display version") { puts AMQPCat::VERSION; exit 0 }
  parser.on("-h", "--help", "Show this help message") { puts parser; exit 0 }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid argument."
    abort parser
  end
end

cat = AMQPCat.new(uri)
case mode
when :producer
  unless exchange || queue
    STDERR.puts "Error: Missing exchange or queue argument."
    abort p
  end
  cat.produce(exchange, routing_key || queue || "", exchange_type, publish_confirm)
when :consumer
  unless routing_key || queue
    STDERR.puts "Error: Missing routing key or queue argument."
    abort p
  end
  cat.consume(exchange, routing_key, queue, queue_type, format, offset)
end
