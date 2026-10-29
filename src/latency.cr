require "amqp-client"

# Latency measurement helpers.
#
# The producer stamps each message with its wall-clock send time (unix
# nanoseconds), either in the `x-sent-at` header or, in perftest compat mode,
# as a 12 byte body prefix (4 byte sequence number + 8 byte timestamp) like
# RabbitMQ PerfTest and omq do. The consumer computes `now - sent`.
# Wall-clock time is used so that it works across processes, which means
# cross-host numbers are only as good as the clock synchronisation.
module Latency
  HEADER     = "x-sent-at"
  PREFIX_LEN = 12

  def self.now_ns : Int64
    t = Time.utc
    t.to_unix * 1_000_000_000_i64 + t.nanosecond
  end

  # Returns the props with the send time stamped in the header
  def self.stamp_header(props : AMQP::Client::Properties) : AMQP::Client::Properties
    headers = AMQP::Client::Arguments.new
    props.headers.try &.each { |k, v| headers[k] = v }
    headers[HEADER] = now_ns
    props.headers = headers
    props
  end

  # Returns the line prefixed with the PerfTest/omq compatible stamp
  def self.stamp_body(line : String, seq : UInt32) : Bytes
    bytes = Bytes.new(PREFIX_LEN + line.bytesize)
    IO::ByteFormat::BigEndian.encode(seq, bytes[0, 4])
    IO::ByteFormat::BigEndian.encode(now_ns.to_u64, bytes[4, 8])
    line.to_slice.copy_to(bytes + PREFIX_LEN)
    bytes
  end

  # Latency of a delivered message, or nil if it carries no (valid) stamp.
  # In compat mode the 12 byte prefix is consumed from the body.
  def self.measure(msg : AMQP::Client::Message, compat : Bool) : Time::Span?
    sent = compat ? read_prefix(msg.body_io) : msg.properties.headers.try { |h| h[HEADER]?.as?(Int64) }
    return unless sent
    # PerfTest stamps in ms with --use-millis, omq accepts both
    sent *= 1_000_000 if sent < 4_102_441_200_000
    Time::Span.new(nanoseconds: now_ns - sent)
  end

  private def self.read_prefix(io : IO::Memory) : Int64?
    return if io.bytesize < PREFIX_LEN
    io.pos += 4
    ts = io.read_bytes(UInt64, IO::ByteFormat::BigEndian)
    ts.to_i64
  end

  # Log-linear histogram, ~3% relative error, nanosecond input.
  # Cheap enough to record every message without allocating.
  class Histogram
    SUB_BUCKETS = 32 # per power of two
    getter count = 0_u64
    @buckets = Array(UInt64).new(64 * SUB_BUCKETS, 0_u64)
    @min = Int64::MAX
    @max = 0_i64

    def record(span : Time::Span)
      ns = Math.max(span.total_nanoseconds.to_i64, 0_i64)
      @buckets[index(ns)] += 1
      @count += 1
      @min = ns if ns < @min
      @max = ns if ns > @max
    end

    def percentile(p : Float64) : Time::Span
      return Time::Span.zero if @count == 0
      target = (p / 100 * @count).ceil.to_u64
      seen = 0_u64
      @buckets.each_with_index do |n, i|
        seen += n
        return Time::Span.new(nanoseconds: Math.min(upper(i), @max)) if seen >= target
      end
      Time::Span.new(nanoseconds: @max)
    end

    def min : Time::Span
      Time::Span.new(nanoseconds: @count == 0 ? 0_i64 : @min)
    end

    def max : Time::Span
      Time::Span.new(nanoseconds: @max)
    end

    def reset
      @buckets.fill(0_u64)
      @count = 0_u64
      @min = Int64::MAX
      @max = 0_i64
    end

    def summary : String
      "min/p50/p95/p99/max = #{fmt min}/#{fmt percentile(50)}/#{fmt percentile(95)}/#{fmt percentile(99)}/#{fmt max}"
    end

    private def fmt(span : Time::Span) : String
      us = span.total_microseconds
      if us < 1000
        "#{us.round(1)} µs"
      elsif us < 1_000_000
        "#{(us / 1000).round(2)} ms"
      else
        "#{(us / 1_000_000).round(2)} s"
      end
    end

    private def index(ns : Int64) : Int32
      return ns.to_i32 if ns < SUB_BUCKETS
      exp = 63 - ns.leading_zeros_count - 5 # ns >> exp is in [32, 64)
      exp * SUB_BUCKETS + (ns >> exp).to_i32
    end

    # Upper bound of bucket i, inverse of index
    private def upper(i : Int32) : Int64
      return i.to_i64 if i < SUB_BUCKETS
      exp = i // SUB_BUCKETS - 1
      ((i % SUB_BUCKETS + SUB_BUCKETS + 1).to_i64 << exp) - 1
    end
  end

  # Prints a line to STDERR every `interval` and once more on `flush`.
  class Stats
    getter latency = Histogram.new
    getter confirm = Histogram.new
    @messages = 0_u64
    @total_messages = 0_u64
    @total = Histogram.new
    @total_confirm = Histogram.new
    @last = Time.instant

    def initialize(@label : String, @interval : Time::Span)
    end

    def start
      spawn do
        loop do
          sleep @interval
          report
        end
      end
    end

    def message(latency : Time::Span?)
      @messages += 1
      latency.try { |l| @latency.record(l); @total.record(l) }
    end

    def confirmed(span : Time::Span)
      @confirm.record(span)
      @total_confirm.record(span)
    end

    def report
      elapsed = Time.instant - @last
      @last = Time.instant
      line = String.build do |io|
        io << @label << ": " << (@messages / elapsed.total_seconds).round(1) << " msg/s"
        io << ", latency " << @latency.summary if @latency.count > 0
        io << ", confirm " << @confirm.summary if @confirm.count > 0
      end
      STDERR.puts line
      @total_messages += @messages
      @messages = 0_u64
      @latency.reset
      @confirm.reset
    end

    # Final summary over the whole run
    def flush
      report
      line = String.build do |io|
        io << @label << " total: " << @total_messages << " msgs"
        io << ", latency " << @total.summary if @total.count > 0
        io << ", confirm " << @total_confirm.summary if @total_confirm.count > 0
      end
      STDERR.puts line
    end
  end
end
