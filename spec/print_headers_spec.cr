require "./spec_helper"

describe "AMQPCat#print_headers" do
  it "prints the contents of nested tables" do
    headers = AMQ::Protocol::Table.new({"x-meta" => {"a" => "b"}})
    io = IO::Memory.new
    AMQPCat.new("amqp://localhost").print_headers(io, headers)
    io.to_s.should eq %(x-meta=AMQ::Protocol::Table(@a="b")\n)
  end
end
