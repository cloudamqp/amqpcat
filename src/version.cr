class AMQPCat
  VERSION = {{ `git describe 2>/dev/null || shards version`.stringify.gsub(/(^v|\n)/, "") }}
end
