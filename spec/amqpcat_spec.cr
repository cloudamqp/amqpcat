require "./spec_helper"

describe AMQPCat do
  it "works" do
    r, w = IO.pipe
    cat = AMQPCat.new("amqp://localhost", r)
    spawn do
      sleep 0.1
      w.puts "hello"
      w.close
    end
    cat.produce("", "test", "direct")
  end
end
