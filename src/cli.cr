require "option_parser"
require "./amqpcat"
require "./version"

uri = "amqp://localhost"
mode = nil
exchange = ""
queue = nil
routing_key = nil
format = "%s\n"

FORMAT_STRING_HELP = <<-HELP
Format string (default "%s\\n")
\t\t\t\t     %e: Exchange name
\t\t\t\t     %r: Routing key
\t\t\t\t     %s: Body, as string
\t\t\t\t     \\n: Newline
\t\t\t\t     \\t: Tab
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
  parser.on("-v", "--version", "Display version") { |v| puts AMQPCat::VERSION; exit 0 }
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
