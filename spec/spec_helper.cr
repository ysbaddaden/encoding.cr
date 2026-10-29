require "spec"
require "json"
require "../src/encoding"

def fixture(name : String) : JSON::Any
  path = File.join(__DIR__, "..", ".cache", "wpt", name)
  unless File.file?(path)
    raise "Missing WPT fixtures; run node tools/import_wpt.js before crystal spec"
  end
  JSON.parse(File.read(path))
end

def bytes(value : JSON::Any) : Bytes
  array = value.as_a
  Bytes.new(array.size) { |i| array[i].as_i.to_u8 }
end

def decode_chunks(input : Bytes, encoding : String, split : Int32, **options) : String
  decoder = Encoding::Decoder.new(encoding, **options)
  decoder.feed(input[0, split]) + decoder.feed(Bytes.empty) + decoder.feed(input[split..]) + decoder.finish
end
