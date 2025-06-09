require "amqp-client"
require "compress/deflate"
require "compress/gzip"
require "mime"
require "./version"

class AMQPCat
  def initialize(uri)
    u = URI.parse(uri)
    p = u.query_params
    p["name"] = "AMQPCat #{VERSION}"
    u.query = p.to_s
    @client = AMQP::Client.new(u)
  end

  def produce(exchange : String, routing_key : String, exchange_type : String, publish_confirm : Bool, props : AMQP::Client::Properties)
    STDIN.blocking = false
    loop do
      connection = @client.connect
      channel = connection.channel
      open_channel_declare_exchange(connection, exchange, exchange_type)
      while line = STDIN.gets
        if publish_confirm
          channel.basic_publish_confirm line, exchange, routing_key, props: props
        else
          channel.basic_publish line, exchange, routing_key, props: props
        end
      end
      connection.close
      break
    rescue ex
      STDERR.puts ex.message
      sleep 2.seconds
    end
  end

  def consume(exchange_name : String, routing_key : String?, queue_name : String?, queue_type : String, format : String, offset = nil, output_dir : String? = nil)
    routing_key ||= ""
    queue_name ||= ""

    if output_dir
      Dir.mkdir(output_dir) unless Dir.exists?(output_dir)
    end

    loop do
      connection = @client.connect
      q = case queue_type
          when "stream"
            stream_queue(connection, queue_name)
          else
            queue(connection, queue_name)
          end
      unless exchange_name.empty? && routing_key.empty?
        q.bind(exchange_name, routing_key)
      end
      args = AMQP::Client::Arguments.new
      args["x-stream-offset"] = offset if offset
      q.subscribe(block: true, no_ack: false, args: args) do |msg|
        if output_dir
          write_message_to_file(msg, output_dir)
        else
          format_output(STDOUT, format, msg)
        end
        msg.ack
      end
    rescue ex
      STDERR.puts ex.message
      sleep 2.seconds
    end
  end

  def rpc(exchange : String, routing_key : String, exchange_type : String, format : String)
    STDIN.blocking = false
    loop do
      connection = @client.connect
      channel = connection.channel
      open_channel_declare_exchange(connection, exchange, exchange_type)
      channel.basic_consume("amq.rabbitmq.reply-to") do |msg|
        format_output(STDOUT, format, msg)
      end
      props = AMQP::Client::Properties.new(reply_to: "amq.rabbitmq.reply-to")
      while line = STDIN.gets
        channel.basic_publish line, exchange, routing_key, props: props
      end
      sleep 1.seconds # wait for the last reply
      connection.close
      break
    rescue ex
      STDERR.puts ex.message
      sleep 2.seconds
    end
  end

  private def queue(connection, name)
    channel = connection.channel
    channel.queue(name, auto_delete: true)
  rescue
    channel = connection.channel
    channel.prefetch 10
    channel.queue(name, passive: true)
  end

  private def stream_queue(connection, name)
    args = AMQP::Client::Arguments.new({
      "x-queue-type": "stream",
    })
    channel = connection.channel
    channel.prefetch 10
    channel.queue(name, auto_delete: false, args: args)
  end

  private def open_channel_declare_exchange(connection, exchange, exchange_type)
    return if exchange == ""
    channel = connection.channel
    channel.exchange_declare exchange, exchange_type, passive: true
    channel
  rescue
    channel = connection.channel
    channel.exchange_declare exchange, exchange_type, passive: false
    channel
  end

  private def decode_payload(msg, io)
    case msg.properties.content_encoding
    when "deflate"
      Compress::Deflate::Reader.open(msg.body_io) do |r|
        IO.copy(r, io)
      end
    when "gzip"
      Compress::Gzip::Reader.open(msg.body_io) do |r|
        IO.copy(r, io)
      end
    else
      IO.copy(msg.body_io, io)
    end
  end

  private def print_headers(io, headers)
    headers.each do |k, v|
      io << k << "=" << v << "\n"
    end
  end

  private def write_message_to_file(msg, dir_path : String)
    # use message ID if available, or correlation ID, otherwise use timestamp
    msg_id = msg.properties.message_id || msg.properties.correlation_id || "#{Time.utc.to_unix_ns}"

    # get appropriate extension based on message properties
    extension = guess_extension(msg.properties.content_type, msg.properties.content_encoding)

    file_path = File.join(dir_path, "#{msg_id}#{extension}")

    File.open(file_path, "w") do |file|
      decode_payload(msg, file)
    end

    STDOUT.puts "#{file_path}"
  end

  private def guess_extension(content_type : String?, content_encoding : String? = nil) : String
    # content_type is preferred over content_encoding
    if content_type
      extensions = MIME.extensions(content_type)
      return "#{extensions.first}" unless extensions.empty?
    end

    if content_encoding == "gzip" || content_encoding == "deflate"
      return ".bin"
    end

    # or maybe its plain text
    return ".txt"
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
          decode_payload(msg, io)
        when 'e'
          io << msg.exchange
        when 'r'
          io << msg.routing_key
        when 'h'
          if headers = msg.properties.headers
            print_headers(io, headers)
          end
        when 't'
          io << msg.properties.content_type
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
