require "./message_formatter"
require "./amqp10_client"

# AMQP 1.0 has no topology frames, so the exchange/queue must already exist
# on the broker; addresses below are only resolved, never declared.
class AMQPCat10
  include MessageFormatter

  def initialize(uri)
    @uri = URI.parse(uri)
  end

  def connect(vhost : String? = nil)
    client = AMQP10::Client.new(@uri, vhost)
    client.connect
    client.close
  end

  def produce(exchange : String, routing_key : String, publish_confirm : Bool, props : AMQ::Protocol::Properties, vhost : String? = nil)
    address, resolved_vhost = resolve_target(exchange, routing_key, vhost)
    IO::FileDescriptor.set_blocking(STDIN.fd, false)
    loop do
      client = AMQP10::Client.new(@uri, resolved_vhost)
      client.connect
      handle = client.attach_sender(address)
      while line = STDIN.gets
        client.publish(handle, props, line.to_slice, publish_confirm)
      end
      client.detach(handle)
      client.close
      break
    rescue ex
      STDERR.puts ex.message
      sleep 2.seconds
    end
  rescue ex : AMQP10::Error
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end

  def consume(exchange_name : String, routing_key : String?, queue_name : String?, format : String, output_dir : String? = nil, vhost : String? = nil)
    address, resolved_vhost = resolve_source(exchange_name, routing_key || "", queue_name || "", vhost)

    if output_dir
      Dir.mkdir(output_dir) unless Dir.exists?(output_dir)
    end

    loop do
      client = AMQP10::Client.new(@uri, resolved_vhost)
      client.connect
      handle = client.attach_receiver(address)
      client.each_message(handle) do |msg|
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
  rescue ex : AMQP10::Error
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end

  # When -e/-r/-q are all left out, falls back to reading an address v2 path
  # straight off the connection URI (e.g. amqp://host/queues/my-queue),
  # since that's exactly what the address scheme looks like. `vhost_override`
  # is --vhost, for when the URI's path is used this way but the broker
  # vhost still needs to be named explicitly.
  private def resolve_target(exchange : String, routing_key : String, vhost_override : String?) : {String, String?}
    if exchange.empty? && routing_key.empty?
      if path = AMQP10::Address.from_uri_path(@uri.path)
        return {path, vhost_override || "/"}
      end
      AMQP10::Address.check_uri_path_not_a_malformed_address!(@uri.path, vhost_override)
    end
    {AMQP10::Address.target(exchange, routing_key), vhost_override}
  end

  private def resolve_source(exchange_name : String, routing_key : String, queue_name : String, vhost_override : String?) : {String, String?}
    if exchange_name.empty? && routing_key.empty? && queue_name.empty?
      if path = AMQP10::Address.from_uri_path(@uri.path)
        if path.starts_with?("/exchanges/")
          raise AMQP10::Error.new("Consuming via an exchange binding isn't supported over AMQP 1.0, use --queue (the queue must already exist on the broker)")
        end
        return {path, vhost_override || "/"}
      end
      AMQP10::Address.check_uri_path_not_a_malformed_address!(@uri.path, vhost_override)
    end
    {AMQP10::Address.source(exchange_name, routing_key, queue_name), vhost_override}
  end
end
