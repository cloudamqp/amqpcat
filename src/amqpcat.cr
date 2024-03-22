require "amqp-client"
require "compress/deflate"
require "compress/gzip"
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
      sleep 2
    end
  end

  def consume(exchange_name : String, routing_key : String?, queue_name : String?, queue_type : String, format : String, offset = nil)
    routing_key ||= ""
    queue_name ||= ""
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
        format_output(STDOUT, format, msg)
        msg.ack
      end
    rescue ex
      STDERR.puts ex.message
      sleep 2
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
      sleep 1 # wait for the last reply
      connection.close
      break
    rescue ex
      STDERR.puts ex.message
      sleep 2
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
