require "./spec_helper"

describe Latency::Histogram do
  it "reports percentiles within a few percent" do
    h = Latency::Histogram.new
    (1..10_000).each { |i| h.record((i * 1000).nanoseconds) } # 1µs..10ms
    h.count.should eq 10_000
    h.min.should eq 1.microsecond
    h.max.should eq 10.milliseconds
    h.percentile(50).total_microseconds.should be_close(5000, 5000 * 0.04)
    h.percentile(99).total_microseconds.should be_close(9900, 9900 * 0.04)
  end

  it "handles small values and reset" do
    h = Latency::Histogram.new
    h.record 5.nanoseconds
    h.percentile(50).should eq 5.nanoseconds
    h.reset
    h.count.should eq 0
  end
end

describe Latency do
  it "stamps a header, keeping existing headers" do
    props = AMQP::Client::Properties.new(headers: AMQP::Client::Arguments.new({"a": "b"}))
    stamped = Latency.stamp_header(props)
    stamped.headers.not_nil!["a"].should eq "b"
    stamped.headers.not_nil![Latency::HEADER].as(Int64).should be_close(Latency.now_ns, 1_000_000_000)
  end

  it "stamps a PerfTest compatible body prefix" do
    bytes = Latency.stamp_body("hello", 7_u32)
    bytes.size.should eq 17
    IO::ByteFormat::BigEndian.decode(UInt32, bytes[0, 4]).should eq 7
    IO::ByteFormat::BigEndian.decode(UInt64, bytes[4, 8]).to_i64.should be_close(Latency.now_ns, 1_000_000_000)
    String.new(bytes[12, 5]).should eq "hello"
  end
end
