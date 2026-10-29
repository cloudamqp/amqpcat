require "amqp-client"
require "./version"
require "./message_formatter"

class AMQPCat
  include MessageFormatter

  def initialize(uri)
    @uri = URI.parse(uri)
    p = @uri.query_params
    p["name"] = "AMQPCat #{VERSION}"
    @uri.query = p.to_s
    @client = AMQP::Client.new(@uri)
  end

  def connect
    @client.connect
  end

  def produce(exchange : String, routing_key : String, exchange_type : String, publish_confirm : Bool, props : AMQP::Client::Properties)
    IO::FileDescriptor.set_blocking(STDIN.fd, false)
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
    IO::FileDescriptor.set_blocking(STDIN.fd, false)
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
end
