require "amqp-client"
require "./version"

class AMQPCat
  def initialize(uri)
    u = URI.parse(uri)
    p = u.query_params
    p["name"] = "AMQPCat #{VERSION}"
    u.query = p.to_s
    @client = AMQP::Client.new(u)
  end

  def produce(exchange : String, routing_key : String, exchange_type : String)
    STDIN.blocking = false
    loop do
      connection = @client.connect
      channel = connection.channel
      declare_exchange(connection, exchange, exchange_type)
      props = AMQP::Client::Properties.new(delivery_mode: 2_u8)
      while line = STDIN.gets
        channel.basic_publish line, exchange, routing_key, props: props
      end
      connection.close
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

  private def declare_exchange(connection, exchange, exchange_type)
    return if exchange == ""
    channel.exchange_declare exchange, exchange_type, passive: true
  rescue
    channel = connection.channel
    channel.exchange_declare exchange, exchange_type, passive: false
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
