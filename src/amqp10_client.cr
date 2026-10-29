require "amqp10-protocol"
require "amq-protocol"
require "socket"
require "openssl"
require "uri"

# A minimal, synchronous AMQP 1.0 client for amqpcat, built directly on the
# wire-level cloudamqp/amqp10-protocol.cr shard, which covers framing, the
# type system and the performatives, but leaves connection/session/link
# state -- and the mapping of messages to an application's own model -- to
# the caller.
#
# Scope: one session and one link (sender or receiver) per connection, which
# is all amqpcat's producer/consumer/connect modes need. AMQP 1.0 has no
# topology frames, so queues/exchanges are never declared here -- they must
# already exist on the broker.
module AMQP10
  class Error < Exception; end

  # Builds a link address from amqpcat's exchange/routing-key/queue options,
  # following RabbitMQ/LavinMQ's "address v2" scheme (see
  # https://www.rabbitmq.com/docs/amqp#addresses).
  module Address
    extend self

    def target(exchange : String, routing_key : String) : String
      if exchange.empty?
        raise Error.new("Missing routing key or queue argument.") if routing_key.empty?
        "/queues/#{URI.encode_path_segment(routing_key)}"
      elsif routing_key.empty?
        "/exchanges/#{URI.encode_path_segment(exchange)}"
      else
        "/exchanges/#{URI.encode_path_segment(exchange)}/#{URI.encode_path_segment(routing_key)}"
      end
    end

    def source(exchange : String, routing_key : String, queue : String) : String
      unless exchange.empty? && routing_key.empty?
        raise Error.new("Consuming via an exchange binding isn't supported over AMQP 1.0, use --queue (the queue must already exist on the broker)")
      end
      raise Error.new("Missing routing key or queue argument.") if queue.empty?
      "/queues/#{URI.encode_path_segment(queue)}"
    end

    # A connection URI's path can itself already be an address v2 path (e.g.
    # amqp://host/queues/my-queue), since that's exactly what the scheme
    # looks like. Recognized so -e/-r/-q don't have to be repeated when the
    # URI already names the queue/exchange.
    def from_uri_path(path : String) : String?
      path if path.starts_with?("/queues/") || path.starts_with?("/exchanges/")
    end

    # With --vhost given explicitly, the URI's path can't also be doing
    # double duty as the vhost -- so once from_uri_path has rejected it, a
    # non-trivial path is almost certainly a typo (e.g. /queue/test instead
    # of /queues/test), not an ordinary vhost. Called instead of falling
    # through to the generic "-e/-r/-q missing" error, which would be
    # misleading given a non-trivial path was clearly supplied.
    def check_uri_path_not_a_malformed_address!(path : String, vhost_override : String?) : Nil
      return unless vhost_override
      return if path.empty? || path == "/"
      raise Error.new("URI path #{path.inspect} isn't a valid address v2 path (expected /queues/:name or " \
                      "/exchanges/:name[/:key]); fix the URI path, or pass -e/-r/-q explicitly.")
    end
  end

  # Encodes/decodes the AMQP 1.0 message sections amqpcat needs, mapping
  # to/from the same AMQ::Protocol::Properties used for AMQP 0-9-1, so the
  # existing format_output/write_message_to_file helpers work unchanged.
  module MessageCodec
    extend self

    def encode(props : AMQ::Protocol::Properties, body : Bytes) : Bytes
      io = IO::Memory.new
      write_header(io, props)
      write_properties(io, props)
      if (headers = props.headers) && !headers.empty?
        write_application_properties(io, headers)
      end
      io.write_byte 0x00_u8
      Protocol::Codec.write_ulong(io, Protocol::Descriptor::DATA)
      Protocol::Codec.write_binary(io, body)
      io.to_slice
    end

    # Parses the message sections starting at `reader`'s current position
    # (right after a transfer performative) through to the end of the frame.
    def parse(reader : IO::Memory) : {AMQ::Protocol::Properties, Bytes}
      props = AMQ::Protocol::Properties.new
      body = Bytes.empty
      while reader.pos < reader.bytesize
        descriptor = Protocol::Codec.read_descriptor_code(reader)
        case descriptor
        when Protocol::Descriptor::HEADER                 then props = parse_header(reader, props)
        when Protocol::Descriptor::PROPERTIES             then props = parse_properties(reader, props)
        when Protocol::Descriptor::APPLICATION_PROPERTIES then props = parse_application_properties(reader, props)
        when Protocol::Descriptor::DATA                   then body = Protocol::Codec.read_binary_value(reader)
        when Protocol::Descriptor::AMQP_VALUE             then body = read_amqp_value_body(reader)
        else                                                   Protocol::Codec.skip_value(reader)
        end
      end
      {props, body}
    end

    private def write_header(io : IO, props : AMQ::Protocol::Properties) : Nil
      durable = props.delivery_mode == 2_u8
      priority = props.priority
      ttl = props.expiration.try(&.to_u32?)
      max_idx = ttl ? 2 : (priority ? 1 : (durable ? 0 : -1))
      return if max_idx < 0
      fields = Array(Protocol::Value).new(max_idx + 1)
      fields << Protocol::Value.bool(durable)
      fields << (priority ? Protocol::Value.ubyte(priority) : Protocol::Value.null) if max_idx >= 1
      fields << (ttl ? Protocol::Value.uint(ttl) : Protocol::Value.null) if max_idx >= 2
      io.write_byte 0x00_u8
      Protocol::Codec.write_ulong(io, Protocol::Descriptor::HEADER)
      Protocol::Codec.write_list(io, fields)
    end

    private def write_properties(io : IO, props : AMQ::Protocol::Properties) : Nil
      return unless props.message_id || props.correlation_id || props.content_type ||
                    props.content_encoding || props.reply_to || props.user_id ||
                    props.type || props.timestamp_raw
      fields = [
        str_or_null(props.message_id),
        bin_or_null(props.user_id),
        Protocol::Value.null, # to
        str_or_null(props.type),
        str_or_null(props.reply_to),
        str_or_null(props.correlation_id),
        sym_or_null(props.content_type),
        sym_or_null(props.content_encoding),
        Protocol::Value.null, # absolute-expiry-time
        ts_or_null(props.timestamp_raw),
      ] of Protocol::Value
      io.write_byte 0x00_u8
      Protocol::Codec.write_ulong(io, Protocol::Descriptor::PROPERTIES)
      Protocol::Codec.write_list(io, fields)
    end

    private def write_application_properties(io : IO, headers : AMQ::Protocol::Table) : Nil
      pairs = Array(Tuple(Protocol::Value, Protocol::Value)).new
      headers.each { |k, v| pairs << {Protocol::Value.string(k), header_value(v)} }
      io.write_byte 0x00_u8
      Protocol::Codec.write_ulong(io, Protocol::Descriptor::APPLICATION_PROPERTIES)
      Protocol::Codec.write_map(io, pairs)
    end

    private def header_value(v) : Protocol::Value
      case v
      when String then Protocol::Value.string(v)
      when Bool   then Protocol::Value.bool(v)
      when Int    then Protocol::Value.long(v.to_i64)
      when Float  then Protocol::Value.double(v.to_f64)
      when Nil    then Protocol::Value.null
      else             Protocol::Value.string(v.to_s)
      end
    end

    private def str_or_null(v : String?) : Protocol::Value
      v ? Protocol::Value.string(v) : Protocol::Value.null
    end

    private def sym_or_null(v : String?) : Protocol::Value
      v ? Protocol::Value.symbol(v) : Protocol::Value.null
    end

    private def bin_or_null(v : String?) : Protocol::Value
      v ? Protocol::Value.binary(v.to_slice) : Protocol::Value.null
    end

    private def ts_or_null(v : Int64?) : Protocol::Value
      v ? Protocol::Value.timestamp(v * 1000) : Protocol::Value.null
    end

    # AMQ::Protocol::Properties is a struct; mutating the argument only
    # mutates this method's own copy, so the (possibly) updated value is
    # returned for the caller to keep.
    private def parse_header(reader : IO::Memory, props : AMQ::Protocol::Properties) : AMQ::Protocol::Properties
      count, end_pos = Protocol::Codec.read_list_header(reader)
      idx = 0
      while idx < count
        case idx
        when 0
          props.delivery_mode = 2_u8 if read_optional_bool(reader)
        when 1
          prio = read_optional_uint(reader)
          props.priority = prio.to_u8 if prio
        when 2
          ttl = read_optional_uint(reader)
          props.expiration = ttl.to_s if ttl
        else
          Protocol::Codec.skip_value(reader)
        end
        idx += 1
      end
      reader.skip(end_pos - reader.pos) if reader.pos < end_pos
      props
    end

    private def parse_properties(reader : IO::Memory, props : AMQ::Protocol::Properties) : AMQ::Protocol::Properties
      count, end_pos = Protocol::Codec.read_list_header(reader)
      idx = 0
      while idx < count
        case idx
        when 0 then props.message_id = short(read_message_id_like(reader))
        when 1 then props.user_id = short(read_binary_or_string(reader))
        when 2 then Protocol::Codec.skip_value(reader) # to: not surfaced on Properties
        when 3 then props.type = short(Protocol::Codec.read_string_value(reader))
        when 4 then props.reply_to = short(Protocol::Codec.read_string_value(reader))
        when 5 then props.correlation_id = short(read_message_id_like(reader))
        when 6 then props.content_type = short(Protocol::Codec.read_string_value(reader))
        when 7 then props.content_encoding = short(Protocol::Codec.read_string_value(reader))
        when 9 then props.timestamp_raw = read_optional_timestamp(reader)
        else        Protocol::Codec.skip_value(reader)
        end
        idx += 1
      end
      reader.skip(end_pos - reader.pos) if reader.pos < end_pos
      props
    end

    private def parse_application_properties(reader : IO::Memory, props : AMQ::Protocol::Properties) : AMQ::Protocol::Properties
      count, end_pos = Protocol::Codec.read_map_header(reader)
      if count > 0
        table = AMQ::Protocol::Table.new
        (count // 2).times do
          key = Protocol::Codec.read_string_value(reader) || ""
          table[key] = read_app_prop_value(reader)
        end
        props.headers = table
      end
      reader.skip(end_pos - reader.pos) if reader.pos < end_pos
      props
    end

    private def short(s : String?) : String?
      s if s && s.bytesize <= 255
    end

    private def read_optional_bool(reader : IO::Memory) : Bool?
      return nil if Protocol::Codec.skip_null?(reader)
      Protocol::Codec.read_bool_value(reader)
    end

    private def read_optional_uint(reader : IO::Memory) : UInt64?
      return nil if Protocol::Codec.skip_null?(reader)
      Protocol::Codec.read_uint_value(reader)
    end

    private def read_optional_timestamp(reader : IO::Memory) : Int64?
      return nil if Protocol::Codec.skip_null?(reader)
      if reader.peek[0]? == 0x83_u8
        reader.skip(1)
        (reader.read_bytes(Int64, IO::ByteFormat::NetworkEndian) // 1000)
      else
        Protocol::Codec.skip_value(reader)
        nil
      end
    end

    # message-id/correlation-id may be string/symbol/ulong/uuid/binary --
    # all coerced to a string for the 0-9-1 model amqpcat uses.
    private def read_message_id_like(reader : IO::Memory) : String?
      case reader.peek[0]?
      when 0x40_u8
        reader.skip(1)
        nil
      when 0xa1_u8, 0xa3_u8, 0xb1_u8, 0xb3_u8
        Protocol::Codec.read_string_value(reader)
      when 0xa0_u8, 0xb0_u8
        Protocol::Codec.read_binary_value(reader).hexstring
      when 0x43_u8, 0x44_u8, 0x50_u8, 0x52_u8, 0x53_u8, 0x60_u8, 0x70_u8, 0x80_u8
        Protocol::Codec.read_uint_value(reader).to_s
      else
        Protocol::Codec.skip_value(reader)
        nil
      end
    end

    private def read_binary_or_string(reader : IO::Memory) : String?
      case reader.peek[0]?
      when 0x40_u8
        reader.skip(1)
        nil
      when 0xa0_u8, 0xb0_u8
        String.new(Protocol::Codec.read_binary_value(reader))
      when 0xa1_u8, 0xa3_u8, 0xb1_u8, 0xb3_u8
        Protocol::Codec.read_string_value(reader)
      else
        Protocol::Codec.skip_value(reader)
        nil
      end
    end

    private def read_app_prop_value(reader : IO::Memory) : AMQ::Protocol::Field
      case reader.peek[0]?
      when 0x40_u8 then reader.skip(1); nil
      when 0x41_u8 then reader.skip(1); true
      when 0x42_u8 then reader.skip(1); false
      when 0xa1_u8, 0xa3_u8, 0xb1_u8, 0xb3_u8
        Protocol::Codec.read_string_value(reader)
      when 0xa0_u8, 0xb0_u8
        String.new(Protocol::Codec.read_binary_value(reader))
      when 0x43_u8, 0x50_u8, 0x52_u8, 0x70_u8, 0x44_u8, 0x53_u8, 0x80_u8
        Protocol::Codec.read_uint_value(reader).to_i64
      when 0x54_u8, 0x55_u8
        reader.skip(1)
        reader.read_bytes(Int8, IO::ByteFormat::NetworkEndian).to_i64
      when 0x71_u8
        reader.skip(1)
        reader.read_bytes(Int32, IO::ByteFormat::NetworkEndian).to_i64
      when 0x81_u8
        reader.skip(1)
        reader.read_bytes(Int64, IO::ByteFormat::NetworkEndian)
      when 0x72_u8
        reader.skip(1)
        reader.read_bytes(Float32, IO::ByteFormat::NetworkEndian).to_f64
      when 0x82_u8
        reader.skip(1)
        reader.read_bytes(Float64, IO::ByteFormat::NetworkEndian)
      else
        Protocol::Codec.skip_value(reader)
        nil
      end
    end

    private def read_amqp_value_body(reader : IO::Memory) : Bytes
      case reader.peek[0]?
      when 0xa0_u8, 0xa1_u8, 0xa3_u8
        len = reader.peek[1].to_i
        reader.skip(2)
        Protocol::Codec.read_slice(reader, len)
      when 0xb0_u8, 0xb1_u8, 0xb3_u8
        reader.skip(1)
        len = Protocol::Codec.read_size32(reader, "amqp-value")
        Protocol::Codec.read_slice(reader, len)
      else
        Protocol::Codec.skip_value(reader)
        Bytes.empty
      end
    end
  end

  # A message received on a receiver link, shaped like AMQP::Client::Message
  # so amqpcat's existing output helpers work unchanged.
  struct Message
    getter exchange : String
    getter routing_key : String
    getter properties : AMQ::Protocol::Properties
    getter body_io : IO::Memory

    # :nodoc:
    def initialize(@client : Client, @handle : UInt32, @delivery_id : UInt32,
                   @properties : AMQ::Protocol::Properties, body : Bytes)
      @exchange = ""
      @routing_key = ""
      @body_io = IO::Memory.new(body)
    end

    def ack : Nil
      @client.accept(@handle, @delivery_id)
    end
  end

  class Client
    DEFAULT_MAX_FRAME = 131_072_u32
    DEFAULT_CREDIT    =      50_u32

    # How much silence from us we tell the broker to tolerate (ms). Half of
    # whatever the broker asks for in return is used as our own heartbeat
    # interval -- see #connect.
    OUR_IDLE_TIMEOUT       = 30_000_u32
    MIN_HEARTBEAT_INTERVAL =  1_000_u32

    @socket : IO?
    @frame_reader : Protocol::FrameReader?
    @tls : Bool
    @host : String
    @port : Int32
    @vhost : String
    @user : String
    @password : String
    @remote_max_frame_size : UInt32
    getter! socket
    getter! frame_reader

    # `vhost` overrides the vhost that would otherwise be derived from the
    # URI's path, for callers that use the path itself as a link address
    # (see AMQP10::Address.from_uri_path) rather than as a vhost.
    def initialize(uri : URI, vhost : String? = nil)
      @tls = uri.scheme == "amqps"
      @host = uri.host.to_s.empty? ? "localhost" : uri.host.to_s
      @port = uri.port || (@tls ? 5671 : 5672)
      @vhost = vhost || (uri.path.bytesize > 1 ? URI.decode_www_form(uri.path[1..-1]) : "/")
      @user = uri.user || "guest"
      @password = uri.password || "guest"
      @channel = 0_u16
      @next_handle = 0_u32
      @next_delivery_id = 0_u32
      @link_credit = 0_u32
      @delivery_count = 0_u32
      @remote_max_frame_size = UInt32::MAX
    end

    def connect : Nil
      tcp = TCPSocket.new(@host, @port, connect_timeout: 60)
      tcp.sync = true
      tcp.tcp_nodelay = true
      io = @tls ? tls_socket(tcp) : tcp.as(IO)
      @socket = io
      sasl_handshake(io)
      io.write Protocol::PROTOCOL_HEADER
      io.flush
      read_protocol_header(io)
      @frame_reader = Protocol::FrameReader.new(io, DEFAULT_MAX_FRAME)
      write_open(io)
      remote_open = Protocol::Open.from_value(expect(Protocol::Descriptor::OPEN))
      @remote_max_frame_size = remote_open.max_frame_size
      if (idle_time_out = remote_open.idle_time_out) && idle_time_out > 0
        interval = Math.max(idle_time_out // 2, MIN_HEARTBEAT_INTERVAL)
        # Reads eventually bottom out on the raw TCP socket even when TLS
        # wraps it, so the timeout is set there regardless of @tls.
        tcp.read_timeout = interval.milliseconds
      end
      write_begin(io)
      expect(Protocol::Descriptor::BEGIN)
    end

    def close : Nil
      return unless io = @socket
      write_end(io)
      write_close(io)
      io.flush
    rescue IO::Error
    ensure
      @socket.try(&.close) rescue nil
    end

    def attach_sender(address : String) : UInt32
      handle = @next_handle
      @next_handle += 1
      write_attach(socket, handle, Protocol::Role::Sender,
        target: Protocol::Target.new(address: address), initial_delivery_count: 0_u32)
      wait_attach(handle)
      wait_flow(handle)
      handle
    end

    def attach_receiver(address : String, credit : UInt32 = DEFAULT_CREDIT) : UInt32
      handle = @next_handle
      @next_handle += 1
      write_attach(socket, handle, Protocol::Role::Receiver, source: Protocol::Source.new(address: address))
      wait_attach(handle)
      send_flow(handle, credit)
      @link_credit = credit
      handle
    end

    def detach(handle : UInt32) : Nil
      write_detach(socket, handle)
    end

    def publish(handle : UInt32, props : AMQ::Protocol::Properties, body : Bytes, confirm : Bool) : Nil
      ensure_credit(handle)
      delivery_id = @next_delivery_id
      @next_delivery_id += 1
      payload = MessageCodec.encode(props, body)
      tag = Bytes.new(4)
      IO::ByteFormat::NetworkEndian.encode(delivery_id, tag)
      settled = !confirm
      perf_size = Protocol::TransferCodec.transfer_performative_size(handle, delivery_id, tag, false, settled)
      frame_size = 8 + perf_size + payload.size
      if frame_size > @remote_max_frame_size
        raise Error.new("Message too large (#{frame_size} bytes) to fit in a single AMQP 1.0 frame " \
                        "(broker's max-frame-size is #{@remote_max_frame_size} bytes); amqpcat10 doesn't " \
                        "support splitting a message across multiple frames.")
      end
      Protocol::FrameWriter.write_frame_header(socket, frame_size.to_u32, Protocol::AMQP_FRAME_TYPE, @channel)
      Protocol::TransferCodec.write_transfer_performative(socket, handle, delivery_id, tag, false, settled)
      socket.write payload
      socket.flush
      @link_credit -= 1 if @link_credit > 0
      wait_confirm(delivery_id) if confirm
    end

    def accept(handle : UInt32, delivery_id : UInt32) : Nil
      Protocol::TransferCodec.write_disposition(socket, @channel, delivery_id, Protocol::Outcome::Accepted,
        settled: true, role: Protocol::Role::Receiver)
    end

    # Blocks forever (or until the link is detached by the broker), yielding
    # every delivered message on `handle`.
    def each_message(handle : UInt32, & : Message ->) : Nil
      loop do
        next unless res = read_frame
        code, value, reader = res
        case code
        when Protocol::Descriptor::TRANSFER
          fields = value.described_value.value.list? || [] of Protocol::Value
          next unless fields[0]?.try(&.uint?).try(&.to_u32) == handle
          delivery_id = fields[1]?.try(&.uint?).try(&.to_u32)
          next unless delivery_id # continuation frames of a fragmented transfer aren't supported
          props, body = MessageCodec.parse(reader)
          @delivery_count += 1
          @link_credit -= 1 if @link_credit > 0
          yield Message.new(self, handle, delivery_id, props, body)
          replenish_credit(handle) if @link_credit <= DEFAULT_CREDIT // 2
        when Protocol::Descriptor::DETACH
          # An errored detach already raised in read_frame; this is a clean one.
          return
        else
          # Ignore flow/disposition/etc arriving unprompted.
        end
      end
    end

    private def ensure_credit(handle : UInt32) : Nil
      while @link_credit.zero?
        next unless res = read_frame
        code, value, _reader = res
        next unless code == Protocol::Descriptor::FLOW
        flow = Protocol::Flow.from_value(value)
        next if flow.handle && flow.handle != handle
        @link_credit = flow.link_credit || 0_u32
      end
    end

    private def wait_confirm(delivery_id : UInt32) : Nil
      loop do
        next unless res = read_frame
        code, value, _reader = res
        next unless code == Protocol::Descriptor::DISPOSITION
        fields = value.described_value.value.list? || [] of Protocol::Value
        first = fields[1]?.try(&.uint?).try(&.to_u32)
        last = fields[2]?.try(&.uint?).try(&.to_u32) || first
        next unless first && last && first <= delivery_id && delivery_id <= last
        state = fields[4]?.try(&.described?)
        case state.try(&.descriptor_code?)
        when Protocol::Descriptor::REJECTED
          raise Error.new("Message rejected by broker")
        when Protocol::Descriptor::RELEASED
          raise Error.new("Message released by broker")
        when Protocol::Descriptor::MODIFIED
          raise Error.new("Message was not accepted (modified) by broker")
        else
          return
        end
      end
    end

    private def wait_attach(handle : UInt32) : Nil
      loop do
        next unless res = read_frame
        code, value, _reader = res
        next unless code == Protocol::Descriptor::ATTACH
        attach = Protocol::Attach.from_value(value)
        next unless attach.handle == handle
        return
      end
    end

    private def wait_flow(handle : UInt32) : Nil
      loop do
        next unless res = read_frame
        code, value, _reader = res
        next unless code == Protocol::Descriptor::FLOW
        flow = Protocol::Flow.from_value(value)
        next if flow.handle && flow.handle != handle
        @link_credit = flow.link_credit || 0_u32
        return
      end
    end

    private def send_flow(handle : UInt32, credit : UInt32) : Nil
      Protocol::TransferCodec.write_flow(socket, @channel, 0_u32, Protocol::DEFAULT_WINDOW,
        0_u32, Protocol::DEFAULT_WINDOW, handle: handle, delivery_count: @delivery_count, link_credit: credit)
    end

    private def replenish_credit(handle : UInt32) : Nil
      send_flow(handle, DEFAULT_CREDIT)
      @link_credit = DEFAULT_CREDIT
    end

    private def tls_socket(tcp : TCPSocket) : OpenSSL::SSL::Socket::Client
      context = OpenSSL::SSL::Context::Client.new
      OpenSSL::SSL::Socket::Client.new(tcp, context, sync_close: true, hostname: @host)
    end

    private def sasl_handshake(io : IO) : Nil
      io.write Protocol::SASL_HEADER
      io.flush
      read_protocol_header(io)
      reader = Protocol::FrameReader.new(io, DEFAULT_MAX_FRAME)

      frame = reader.read
      value = Protocol::Codec.decode(frame.body_reader)
      unless value.descriptor_code? == Protocol::Descriptor::SASL_MECHANISMS
        raise Error.new("Expected sasl-mechanisms from broker")
      end

      response = IO::Memory.new
      response.write_byte 0_u8
      response << @user
      response.write_byte 0_u8
      response << @password
      write_sasl_init(io, "PLAIN", response.to_slice)

      frame = reader.read
      value = Protocol::Codec.decode(frame.body_reader)
      unless value.descriptor_code? == Protocol::Descriptor::SASL_OUTCOME
        raise Error.new("Expected sasl-outcome from broker")
      end
      fields = value.described_value.value.list?
      code = fields.try(&.[0]?).try(&.uint?)
      raise Error.new("SASL authentication failed (code #{code})") unless code == 0_u64
    end

    private def read_protocol_header(io : IO) : Nil
      buf = Bytes.new(8)
      io.read_fully(buf)
    end

    private def write_open(io : IO) : Nil
      # RabbitMQ picks a non-default vhost from the open frame's hostname
      # field only when it's prefixed with "vhost:" -- an unprefixed value
      # is ignored in favor of the broker's default_vhost (usually "/"), so
      # the plain vhost name alone silently selects the wrong vhost.
      hostname = @vhost.empty? || @vhost == "/" ? nil : "vhost:#{@vhost}"
      open = Protocol::Open.new("amqpcat", hostname, DEFAULT_MAX_FRAME, nil, OUR_IDLE_TIMEOUT)
      Protocol::FrameWriter.write_frame_header(io, open.frame_size, Protocol::AMQP_FRAME_TYPE, @channel)
      open.write_body(io)
      io.flush
    end

    # An "empty frame" (frame header, no body) used to avoid tripping the
    # broker's idle-time-out while we're otherwise just blocked reading.
    private def send_heartbeat : Nil
      Protocol::FrameWriter.write_frame_header(socket, 8_u32, Protocol::AMQP_FRAME_TYPE, @channel)
      socket.flush
    end

    private def write_begin(io : IO) : Nil
      fields = [
        Protocol::Value.null, # remote-channel
        Protocol::Value.uint(0_u32),
        Protocol::Value.uint(Protocol::DEFAULT_WINDOW),
        Protocol::Value.uint(Protocol::DEFAULT_WINDOW),
      ] of Protocol::Value
      Protocol::FrameWriter.write_performative(io, @channel, Protocol::AMQP_FRAME_TYPE, Protocol::Descriptor::BEGIN, fields)
    end

    private def write_attach(io : IO, handle : UInt32, role : Protocol::Role,
                             source : Protocol::Source? = nil, target : Protocol::Target? = nil,
                             initial_delivery_count : UInt32? = nil) : Nil
      fields = [
        Protocol::Value.string("amqpcat-#{handle}"),
        Protocol::Value.uint(handle),
        Protocol::Value.bool(role.receiver?),
        Protocol::Value.null, # snd-settle-mode
        Protocol::Value.null, # rcv-settle-mode
        source ? source.to_value : Protocol::Value.null,
        target ? target.to_value : Protocol::Value.null,
        Protocol::Value.null, # unsettled
        Protocol::Value.null, # incomplete-unsettled
      ] of Protocol::Value
      fields << Protocol::Value.uint(initial_delivery_count) if initial_delivery_count
      Protocol::FrameWriter.write_performative(io, @channel, Protocol::AMQP_FRAME_TYPE, Protocol::Descriptor::ATTACH, fields)
    end

    private def write_detach(io : IO, handle : UInt32) : Nil
      fields = [Protocol::Value.uint(handle), Protocol::Value.bool(true)] of Protocol::Value
      Protocol::FrameWriter.write_performative(io, @channel, Protocol::AMQP_FRAME_TYPE, Protocol::Descriptor::DETACH, fields)
    end

    private def write_end(io : IO) : Nil
      Protocol::FrameWriter.write_empty_performative(io, @channel, Protocol::Descriptor::END)
    end

    private def write_close(io : IO) : Nil
      Protocol::FrameWriter.write_empty_performative(io, @channel, Protocol::Descriptor::CLOSE)
    end

    private def write_sasl_init(io : IO, mechanism : String, response : Bytes) : Nil
      fields = [
        Protocol::Value.symbol(mechanism),
        Protocol::Value.binary(response),
        Protocol::Value.null, # hostname
      ] of Protocol::Value
      Protocol::FrameWriter.write_performative(io, 0_u16, Protocol::SASL_FRAME_TYPE, Protocol::Descriptor::SASL_INIT, fields)
    end

    # Reads one frame off the wire, decodes its performative, and returns
    # {descriptor-code, value, reader}, with reader positioned right after
    # the performative's fields (e.g. at a transfer's message bytes). Returns
    # nil for an empty (heartbeat) frame, or when our own read timed out and
    # we sent one of our own to keep the broker's idle-time-out happy (the
    # FrameReader is resumable, so the next call picks up any partial frame
    # that read was interrupted on). Raises if the broker closes the
    # connection or ends the session.
    private def read_frame : {UInt64, Protocol::Value, IO::Memory}?
      frame = begin
        frame_reader.read
      rescue IO::TimeoutError
        send_heartbeat
        return nil
      end
      return nil if frame.body.empty?
      reader = frame.body_reader
      value = Protocol::Codec.decode(reader)
      code = value.descriptor_code? || raise Error.new("Received a non-described AMQP 1.0 performative")
      case code
      when Protocol::Descriptor::CLOSE
        raise Error.new("Connection closed by broker#{error_suffix(value)}")
      when Protocol::Descriptor::END
        raise Error.new("Session ended by broker#{error_suffix(value)}")
      when Protocol::Descriptor::DETACH
        fields = value.described_value.value.list?
        error = fields.try(&.[2]?)
        if error && !error.null?
          raise Error.new("Link detached by broker#{error_suffix(value)}")
        end
      end
      {code, value, reader}
    end

    # Loops past heartbeat ticks (both incoming empty frames and our own,
    # sent in response to a read timeout) until the expected performative
    # arrives.
    private def expect(descriptor : UInt64) : Protocol::Value
      loop do
        res = read_frame
        next unless res
        _, value, _ = res
        code = value.descriptor_code?
        raise Error.new("Unexpected AMQP 1.0 frame (wanted #{descriptor}, got #{code})") unless code == descriptor
        return value
      end
    end

    private def error_suffix(value : Protocol::Value) : String
      fields = value.described_value.value.list?
      error = fields.try(&.last?).try(&.described?)
      return "" unless error && error.descriptor_code? == Protocol::Descriptor::ERROR
      efields = error.value.list?
      condition = efields.try(&.[0]?).try(&.string_like?)
      return "" unless condition
      description = efields.try(&.[1]?).try(&.string_like?)
      description ? ": #{condition} (#{description})" : ": #{condition}"
    end
  end
end
