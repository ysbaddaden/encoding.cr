require "./encoding/data"
require "./encoding/errors"
require "./encoding/table"
require "./encoding/decoder"
require "./encoding/encoder"
require "./encoding/io"

# Pure Crystal conversion using the WHATWG Encoding Standard's mappings.
module Encoding
  VERSION = "0.1.0"

  enum ErrorMode
    Replace
    Strict
  end

  enum BOMPolicy
    Detect
    Strip
    Preserve
  end

  private BOM_SIGNATURES = {
    {"UTF-8", {0xef_u8, 0xbb_u8, 0xbf_u8}},
    {"UTF-16LE", {0xff_u8, 0xfe_u8}},
    {"UTF-16BE", {0xfe_u8, 0xff_u8}},
  }

  struct Descriptor
    getter name : String

    protected def initialize(@name : String)
    end

    def can_decode? : Bool
      true
    end

    def can_encode? : Bool
      @name != "replacement"
    end

    def decoder(*, errors : ErrorMode = :replace, replacement : String = "\uFFFD", bom : BOMPolicy = :detect) : Decoder
      Decoder.new(@name, errors: errors, replacement: replacement, bom: bom)
    end

    def encoder(*, errors : ErrorMode = :replace, replacement : String = "?", bom : Bool = false) : Encoder
      Encoder.new(@name, errors: errors, replacement: replacement, bom: bom)
    end
  end

  def self.find(label : String) : Descriptor
    normalized = label.strip("\t\n\f\r ").downcase(:ascii)
    name = Data::LABELS[normalized]? || raise UnknownEncodingError.new("Unknown encoding: #{label.inspect}")
    Descriptor.new(name)
  end

  def self.encodings : Array(Descriptor)
    Data::LABELS.values.uniq.map { |name| Descriptor.new(name) }
  end

  def self.decode(bytes : Bytes, encoding : String = "utf-8", *, errors : ErrorMode = :replace,
                  replacement : String = "\uFFFD", bom : BOMPolicy = :detect) : String
    decoder = Decoder.new(encoding, errors: errors, replacement: replacement, bom: bom)
    String.build do |output|
      decoder.feed(bytes, output)
      decoder.finish(output)
    end
  end

  def self.encode(text : String | Bytes, encoding : String = "utf-8", *, errors : ErrorMode = :replace,
                  replacement : String = "?", bom : Bool = false) : Bytes
    encoder = Encoder.new(encoding, errors: errors, replacement: replacement, bom: bom)
    output = IO::Memory.new
    encoder.feed(text, output)
    encoder.finish(output)
    output.to_slice
  end
end
