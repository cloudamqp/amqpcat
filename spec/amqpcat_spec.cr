require "./spec_helper"

describe AMQPCat do
  it "works" do

    client = AMQP::Client.new
    channel = client.connect.channel
    q = channel.queue "amqpcat-1"
    q.purge

    r, w = IO.pipe
    cat = AMQPCat.new("amqp://localhost", r)
    spawn do
      sleep 0.1
      w.puts "hello"
      w.close
    end
    cat.produce("", "amqpcat-1", "direct")

    sleep 1
    msg = q.get
    msg.should_not be_nil
    msg.not_nil!.body_io.to_s.should eq "hello"
  end
end
