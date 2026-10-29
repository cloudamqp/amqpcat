require "./spec_helper"
require "socket"

# A minimal fake AMQP 1.0 broker, built independently from AMQP10::Client's
# own writers/readers (straight off the amqp10-protocol.cr primitives), used
# to drive AMQP10::Client through a real handshake -> attach -> transfer ->
# disposition round trip over a loopback TCP socket.
private module FakeBroker
  extend self

  alias P = AMQP10::Protocol

  # Performs SASL (always succeeds) and the open/begin handshake, mirroring
  # what a real broker does. Returns the shared FrameReader for the session.
  def handshake(socket : IO, max_frame_size : UInt32 = 131_072_u32, idle_time_out : UInt32? = nil,
                on_open : (P::Open ->)? = nil) : AMQP10::Protocol::FrameReader
    buf = Bytes.new(8)
    socket.read_fully(buf) # client's SASL header
    socket.write P::SASL_HEADER
    socket.flush

    sasl_reader = P::FrameReader.new(socket, 131_072_u32)
    mechanisms = [P::Value.array([P::Value.symbol("PLAIN")])] of P::Value
    P::FrameWriter.write_performative(socket, 0_u16, P::SASL_FRAME_TYPE, P::Descriptor::SASL_MECHANISMS, mechanisms)

    frame = sasl_reader.read
    init = P::Codec.decode(frame.body_reader)
    raise "expected sasl-init" unless init.descriptor_code? == P::Descriptor::SASL_INIT

    outcome = [P::Value.ubyte(0_u8)] of P::Value
    P::FrameWriter.write_performative(socket, 0_u16, P::SASL_FRAME_TYPE, P::Descriptor::SASL_OUTCOME, outcome)

    socket.read_fully(buf) # client's AMQP header
    socket.write P::PROTOCOL_HEADER
    socket.flush

    reader = P::FrameReader.new(socket, 131_072_u32)
    frame = reader.read
    open = P::Codec.decode(frame.body_reader)
    raise "expected open" unless open.descriptor_code? == P::Descriptor::OPEN
    on_open.try &.call(P::Open.from_value(open))

    our_open = P::Open.new("fake-broker", nil, max_frame_size, nil, idle_time_out)
    P::FrameWriter.write_frame_header(socket, our_open.frame_size, P::AMQP_FRAME_TYPE, 0_u16)
    our_open.write_body(socket)
    socket.flush

    frame = reader.read
    begin_value = P::Codec.decode(frame.body_reader)
    raise "expected begin" unless begin_value.descriptor_code? == P::Descriptor::BEGIN

    begin_fields = [
      P::Value.null,
      P::Value.uint(0_u32),
      P::Value.uint(P::DEFAULT_WINDOW),
      P::Value.uint(P::DEFAULT_WINDOW),
    ] of P::Value
    P::FrameWriter.write_performative(socket, 0_u16, P::AMQP_FRAME_TYPE, P::Descriptor::BEGIN, begin_fields)

    reader
  end

  # Reads an attach, replies with an attach mirroring the role, and returns
  # the link handle.
  def accept_attach(socket : IO, reader : AMQP10::Protocol::FrameReader) : UInt32
    frame = reader.read
    value = P::Codec.decode(frame.body_reader)
    raise "expected attach" unless value.descriptor_code? == P::Descriptor::ATTACH
    attach = P::Attach.from_value(value)

    fields = [
      P::Value.string(attach.name),
      P::Value.uint(attach.handle),
      P::Value.bool(!attach.role.receiver?),
      P::Value.null,
      P::Value.null,
      attach.source.try(&.to_value) || P::Value.null,
      attach.target.try(&.to_value) || P::Value.null,
      P::Value.null,
      P::Value.null,
      P::Value.uint(0_u32),
    ] of P::Value
    P::FrameWriter.write_performative(socket, 0_u16, P::AMQP_FRAME_TYPE, P::Descriptor::ATTACH, fields)
    attach.handle
  end

  def send_flow(socket : IO, handle : UInt32, credit : UInt32) : Nil
    P::TransferCodec.write_flow(socket, 0_u16, 0_u32, P::DEFAULT_WINDOW, 0_u32, P::DEFAULT_WINDOW,
      handle: handle, delivery_count: 0_u32, link_credit: credit)
  end

  # Reads one transfer, returning {delivery-id, body-bytes}.
  def read_transfer(reader : AMQP10::Protocol::FrameReader) : {UInt32, Bytes}
    frame = reader.read
    r = frame.body_reader
    value = P::Codec.decode(r)
    raise "expected transfer" unless value.descriptor_code? == P::Descriptor::TRANSFER
    fields = value.described_value.value.list?.not_nil!
    delivery_id = fields[1].uint?.not_nil!.to_u32
    props, body = AMQP10::MessageCodec.parse(r)
    {delivery_id, body}
  end

  def accept_delivery(socket : IO, delivery_id : UInt32) : Nil
    P::TransferCodec.write_disposition(socket, 0_u16, delivery_id, P::Outcome::Accepted, settled: true, role: P::Role::Receiver)
  end

  def send_message(socket : IO, handle : UInt32, delivery_id : UInt32, body : Bytes) : Nil
    payload = AMQP10::MessageCodec.encode(AMQ::Protocol::Properties.new, body)
    tag = Bytes.new(4)
    IO::ByteFormat::NetworkEndian.encode(delivery_id, tag)
    perf_size = P::TransferCodec.transfer_performative_size(handle, delivery_id, tag, false, true)
    frame_size = 8 + perf_size + payload.size
    P::FrameWriter.write_frame_header(socket, frame_size.to_u32, P::AMQP_FRAME_TYPE, 0_u16)
    P::TransferCodec.write_transfer_performative(socket, handle, delivery_id, tag, false, true)
    socket.write payload
    socket.flush
  end

  def read_disposition(reader : AMQP10::Protocol::FrameReader) : Nil
    frame = reader.read
    value = P::Codec.decode(frame.body_reader)
    raise "expected disposition" unless value.descriptor_code? == P::Descriptor::DISPOSITION
  end
end

private def with_fake_broker(& : TCPServer ->)
  server = TCPServer.new("127.0.0.1", 0)
  yield server
ensure
  server.try &.close
end

describe AMQP10::Client do
  it "publishes a message and waits for the broker's confirm" do
    with_fake_broker do |server|
      result = Channel(Exception?).new
      received = Channel(Bytes).new

      spawn do
        socket = server.accept
        reader = FakeBroker.handshake(socket)
        handle = FakeBroker.accept_attach(socket, reader)
        FakeBroker.send_flow(socket, handle, 10_u32)
        delivery_id, body = FakeBroker.read_transfer(reader)
        FakeBroker.accept_delivery(socket, delivery_id)
        received.send(body)
        result.send(nil)
      rescue ex
        result.send(ex)
      ensure
        socket.try &.close
      end

      uri = URI.parse("amqp://guest:guest@127.0.0.1:#{server.local_address.port}/")
      client = AMQP10::Client.new(uri)
      client.connect
      handle = client.attach_sender("/queues/test")
      props = AMQ::Protocol::Properties.new(content_type: "text/plain")
      client.publish(handle, props, "hello amqp 1.0".to_slice, true)

      body = received.receive
      String.new(body).should eq "hello amqp 1.0"

      err = result.receive
      raise err if err
      client.close
    end
  end

  it "attaches a receiver, consumes a message and acks it" do
    with_fake_broker do |server|
      result = Channel(Exception?).new
      acked = Channel(Nil).new

      spawn do
        socket = server.accept
        reader = FakeBroker.handshake(socket)
        handle = FakeBroker.accept_attach(socket, reader)
        flow_frame = reader.read
        flow_value = AMQP10::Protocol::Codec.decode(flow_frame.body_reader)
        raise "expected flow" unless flow_value.descriptor_code? == AMQP10::Protocol::Descriptor::FLOW

        FakeBroker.send_message(socket, handle, 0_u32, "consumed body".to_slice)
        FakeBroker.read_disposition(reader)
        acked.send(nil)
        result.send(nil)
      rescue ex
        result.send(ex)
      ensure
        socket.try &.close
      end

      uri = URI.parse("amqp://guest:guest@127.0.0.1:#{server.local_address.port}/")
      client = AMQP10::Client.new(uri)
      client.connect
      handle = client.attach_receiver("/queues/test")

      body = nil
      client.each_message(handle) do |msg|
        body = msg.body_io.gets_to_end
        msg.ack
        break
      end

      acked.receive
      err = result.receive
      raise err if err

      body.should eq "consumed body"
      client.close rescue nil
    end
  end

  it "rejects publishing a message larger than the broker's max-frame-size" do
    with_fake_broker do |server|
      result = Channel(Exception?).new

      spawn do
        socket = server.accept
        reader = FakeBroker.handshake(socket, max_frame_size: 1_024_u32)
        handle = FakeBroker.accept_attach(socket, reader)
        FakeBroker.send_flow(socket, handle, 10_u32)
        result.send(nil)
      rescue ex
        result.send(ex)
      ensure
        socket.try &.close
      end

      uri = URI.parse("amqp://guest:guest@127.0.0.1:#{server.local_address.port}/")
      client = AMQP10::Client.new(uri)
      client.connect
      handle = client.attach_sender("/queues/test")

      err = result.receive
      raise err if err

      props = AMQ::Protocol::Properties.new
      body = Bytes.new(2_000)
      expect_raises(AMQP10::Error, /too large/) do
        client.publish(handle, props, body, false)
      end
      client.close rescue nil
    end
  end

  it "prefixes a non-default vhost with vhost: in the open frame's hostname, as RabbitMQ requires" do
    with_fake_broker do |server|
      result = Channel(Exception?).new
      hostname = Channel(String?).new(1)

      spawn do
        socket = server.accept
        FakeBroker.handshake(socket, on_open: ->(open : AMQP10::Protocol::Open) { hostname.send(open.hostname) })
        result.send(nil)
      rescue ex
        result.send(ex)
      ensure
        socket.try &.close
      end

      uri = URI.parse("amqp://guest:guest@127.0.0.1:#{server.local_address.port}/")
      client = AMQP10::Client.new(uri, "my-vhost")
      client.connect

      hostname.receive.should eq "vhost:my-vhost"
      err = result.receive
      raise err if err
      client.close rescue nil
    end
  end

  it "sends heartbeats while idle, honoring the broker's idle-time-out" do
    with_fake_broker do |server|
      result = Channel(Exception?).new
      heartbeats = Channel(Nil).new

      spawn do
        socket = server.accept
        # A 2s idle-time-out means the client should heartbeat at ~1s.
        reader = FakeBroker.handshake(socket, idle_time_out: 2_000_u32)
        handle = FakeBroker.accept_attach(socket, reader)
        flow_frame = reader.read # the receiver's initial credit-granting flow
        flow_value = AMQP10::Protocol::Codec.decode(flow_frame.body_reader)
        raise "expected flow" unless flow_value.descriptor_code? == AMQP10::Protocol::Descriptor::FLOW

        2.times do
          frame = reader.read
          raise "expected an empty (heartbeat) frame" unless frame.body.empty?
          heartbeats.send(nil)
        end
        result.send(nil)
      rescue ex
        result.send(ex)
      ensure
        socket.try &.close
      end

      uri = URI.parse("amqp://guest:guest@127.0.0.1:#{server.local_address.port}/")
      client = AMQP10::Client.new(uri)
      client.connect
      handle = client.attach_receiver("/queues/test")

      # Keep the client blocked reading (as a real consumer would) so idle
      # time actually passes and the read-timeout-driven heartbeat fires.
      spawn do
        client.each_message(handle) { }
      rescue
      end

      2.times { heartbeats.receive }
      err = result.receive
      raise err if err
      client.close rescue nil
    end
  end
end
