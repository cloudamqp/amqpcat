require "./spec_helper"

describe AMQP10::MessageCodec do
  it "round-trips properties, headers and body through AMQP 1.0 message sections" do
    headers = AMQ::Protocol::Table.new
    headers["x-foo"] = "bar"
    headers["x-num"] = 42_i64
    headers["x-bool"] = true

    props = AMQ::Protocol::Properties.new(
      content_type: "text/plain",
      content_encoding: "identity",
      delivery_mode: 2_u8,
      priority: 5_u8,
      correlation_id: "corr-1",
      reply_to: "amq.rabbitmq.reply-to",
      expiration: "60000",
      message_id: "abc123",
      type: "my-type",
      headers: headers,
    )
    props.timestamp_raw = 1700000000_i64

    body = "hello world".to_slice
    encoded = AMQP10::MessageCodec.encode(props, body)

    reader = IO::Memory.new(encoded)
    parsed_props, parsed_body = AMQP10::MessageCodec.parse(reader)

    String.new(parsed_body).should eq "hello world"
    parsed_props.content_type.should eq "text/plain"
    parsed_props.content_encoding.should eq "identity"
    parsed_props.delivery_mode.should eq 2_u8
    parsed_props.priority.should eq 5_u8
    parsed_props.correlation_id.should eq "corr-1"
    parsed_props.reply_to.should eq "amq.rabbitmq.reply-to"
    parsed_props.expiration.should eq "60000"
    parsed_props.message_id.should eq "abc123"
    parsed_props.type.should eq "my-type"
    parsed_props.timestamp_raw.should eq 1700000000_i64

    parsed_headers = parsed_props.headers.not_nil!
    parsed_headers["x-foo"].should eq "bar"
    parsed_headers["x-num"].should eq 42_i64
    parsed_headers["x-bool"].should eq true
  end

  it "encodes nothing but the body when properties are empty" do
    props = AMQ::Protocol::Properties.new
    body = "just a body".to_slice
    encoded = AMQP10::MessageCodec.encode(props, body)

    reader = IO::Memory.new(encoded)
    parsed_props, parsed_body = AMQP10::MessageCodec.parse(reader)

    String.new(parsed_body).should eq "just a body"
    parsed_props.content_type.should be_nil
    parsed_props.headers.should be_nil
  end
end

describe AMQP10::Address do
  it "builds a default-exchange target from a routing key" do
    AMQP10::Address.target("", "my-queue").should eq "/queues/my-queue"
  end

  it "builds an exchange target with a routing key" do
    AMQP10::Address.target("my-exchange", "my-key").should eq "/exchanges/my-exchange/my-key"
  end

  it "builds an exchange target without a routing key" do
    AMQP10::Address.target("my-exchange", "").should eq "/exchanges/my-exchange"
  end

  it "percent-encodes special characters in exchange and routing key" do
    AMQP10::Address.target("amq.direct", "my-routing_key/123").should eq "/exchanges/amq.direct/my-routing_key%2F123"
  end

  it "rejects a missing routing key or queue for the default exchange" do
    expect_raises(AMQP10::Error, /Missing/) do
      AMQP10::Address.target("", "")
    end
  end

  it "builds a source address from a queue name" do
    AMQP10::Address.source("", "", "my-queue").should eq "/queues/my-queue"
  end

  it "rejects consuming via an exchange binding" do
    expect_raises(AMQP10::Error, /exchange binding/) do
      AMQP10::Address.source("my-exchange", "my-key", "")
    end
  end

  it "rejects a missing queue" do
    expect_raises(AMQP10::Error, /Missing/) do
      AMQP10::Address.source("", "", "")
    end
  end

  it "recognizes an address v2 path lifted from a connection URI" do
    AMQP10::Address.from_uri_path("/queues/my-queue").should eq "/queues/my-queue"
    AMQP10::Address.from_uri_path("/exchanges/my-exchange/my-key").should eq "/exchanges/my-exchange/my-key"
  end

  it "doesn't mistake an ordinary vhost path for an address" do
    AMQP10::Address.from_uri_path("/my-vhost").should be_nil
    AMQP10::Address.from_uri_path("/").should be_nil
    AMQP10::Address.from_uri_path("").should be_nil
  end

  it "rejects a malformed address-looking path once --vhost is given" do
    expect_raises(AMQP10::Error, /isn't a valid address v2 path/) do
      AMQP10::Address.check_uri_path_not_a_malformed_address!("/queue/test", "my-vhost")
    end
  end

  it "doesn't flag a path when --vhost wasn't given (it's an ordinary vhost)" do
    AMQP10::Address.check_uri_path_not_a_malformed_address!("/queue/test", nil).should be_nil
  end

  it "doesn't flag the root/empty path even with --vhost given" do
    AMQP10::Address.check_uri_path_not_a_malformed_address!("/", "my-vhost").should be_nil
    AMQP10::Address.check_uri_path_not_a_malformed_address!("", "my-vhost").should be_nil
  end
end
