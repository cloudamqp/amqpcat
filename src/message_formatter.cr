require "compress/deflate"
require "compress/gzip"
require "mime"

# Output formatting shared by AMQPCat (AMQP 0-9-1) and AMQPCat10 (AMQP 1.0).
# Methods are duck-typed over `msg` so they work with either client's
# message type.
module MessageFormatter
  private def decode_payload(msg, io)
    case msg.properties.content_encoding
    when "deflate"
      Compress::Deflate::Reader.open(msg.body_io) do |r|
        IO.copy(r, io)
      end
    when "gzip"
      Compress::Gzip::Reader.open(msg.body_io) do |r|
        IO.copy(r, io)
      end
    else
      IO.copy(msg.body_io, io)
    end
  end

  def print_headers(io, headers)
    headers.each do |k, v|
      io << k << "="
      if v.is_a?(AMQ::Protocol::Table)
        v.inspect(io)
      else
        io << v
      end
      io << "\n"
    end
  end

  private def write_message_to_file(msg, dir_path : String)
    # use message ID if available, or correlation ID, otherwise use timestamp
    msg_id = msg.properties.message_id || msg.properties.correlation_id || "#{Time.utc.to_unix_ns}"

    # get appropriate extension based on message properties
    extension = guess_extension(msg.properties.content_type, msg.properties.content_encoding)

    file_path = File.join(dir_path, "#{msg_id}#{extension}")

    File.open(file_path, "w") do |file|
      decode_payload(msg, file)
    end

    STDOUT.puts "#{file_path}"
  end

  private def guess_extension(content_type : String?, content_encoding : String? = nil) : String
    # content_type is preferred over content_encoding
    if content_type
      extensions = MIME.extensions(content_type)
      return "#{extensions.first}" unless extensions.empty?
    end

    if content_encoding == "gzip" || content_encoding == "deflate"
      return ".bin"
    end

    # or maybe its plain text
    return ".txt"
  end

  private def format_output(io, format_str, msg)
    io.sync = false
    match = false
    escape = false
    Char::Reader.new(format_str).each do |c|
      if c == '%'
        match = true
      elsif match
        case c
        when 's'
          decode_payload(msg, io)
        when 'e'
          io << msg.exchange
        when 'r'
          io << msg.routing_key
        when 'h'
          if headers = msg.properties.headers
            print_headers(io, headers)
          end
        when 't'
          io << msg.properties.content_type
        when '%'
          io << '%'
        else
          raise "Invalid substitution argument '%#{c}'"
        end
        match = false
      elsif c == '\\'
        escape = true
      elsif escape
        case c
        when 'n'
          io << '\n'
        when 't'
          io << '\t'
        else
          raise "Invalid escape character '\#{c}'"
        end
        escape = false
      else
        io << c
      end
    end
    io.flush
  end
end
