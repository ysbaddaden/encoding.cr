require "./spec_helper"

describe "UTF-32" do
  vectors = {
    "utf-32le" => Bytes[0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00, 0xff, 0xd7, 0x00, 0x00, 0x00, 0xe0, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xa9, 0xf4, 0x01, 0x00, 0xff, 0xff, 0x10, 0x00],
    "utf-32be" => Bytes[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0xd7, 0xff, 0x00, 0x00, 0xe0, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0xf4, 0xa9, 0x00, 0x10, 0xff, 0xff],
  }
  text = "\0A\uD7FF\uE000\uFFFF\u{10000}💩\u{10FFFF}"

  it "registers the extension labels and descriptors" do
    Encoding.find(" UTF-32 ").name.should eq("UTF-32LE")
    Encoding.find("UtF-32bE").name.should eq("UTF-32BE")
    Encoding.encodings.map(&.name).should contain("UTF-32LE")
    Encoding.encodings.map(&.name).should contain("UTF-32BE")
  end

  vectors.each do |encoding, input|
    it "converts #{encoding} scalars across every input split" do
      Encoding.encode(text, encoding, errors: Encoding::ErrorMode::Strict).should eq(input)
      (0..input.size).each do |split|
        decode_chunks(input, encoding, split, errors: Encoding::ErrorMode::Strict, bom: Encoding::BOMPolicy::Preserve).should eq(text)
      end
      (0..text.bytesize).each do |split|
        encoder = Encoding::Encoder.new(encoding, errors: Encoding::ErrorMode::Strict)
        result = encoder.feed(text.to_slice[0, split]).to_a
        result.concat(encoder.feed(text.to_slice[split..]).to_a)
        result.concat(encoder.finish.to_a)
        result.should eq(input.to_a)
      end
    end

    it "rejects invalid #{encoding} scalars and reports absolute offsets" do
      {0xd800_u32, 0xdfff_u32, 0x110000_u32, 0xffffffff_u32}.each do |scalar|
        invalid = Bytes.new(4) { |i| ((scalar >> (encoding == "utf-32le" ? i * 8 : (3 - i) * 8)) & 0xff).to_u8 }
        bytes = Encoding.encode("A", encoding) + invalid + Encoding.encode("B", encoding)
        (0..bytes.size).each do |split|
          decode_chunks(bytes, encoding, split, bom: Encoding::BOMPolicy::Preserve).should eq("A�B")
          error = expect_raises(Encoding::InvalidByteSequenceError) do
            decode_chunks(bytes, encoding, split, errors: Encoding::ErrorMode::Strict, bom: Encoding::BOMPolicy::Preserve)
          end
          error.offset.should eq(4)
        end
      end
    end

    it "handles truncated #{encoding} units at EOF" do
      (1..3).each do |size|
        bytes = Encoding.encode("A", encoding) + Bytes.new(size)
        (0..bytes.size).each do |split|
          decode_chunks(bytes, encoding, split, bom: Encoding::BOMPolicy::Preserve).should eq("A�")
          decode_chunks(bytes, encoding, split, replacement: "", bom: Encoding::BOMPolicy::Preserve).should eq("A")
          expect_raises(Encoding::InvalidByteSequenceError) do
            decode_chunks(bytes, encoding, split, errors: Encoding::ErrorMode::Strict, bom: Encoding::BOMPolicy::Preserve)
          end.offset.should eq(4)
        end
      end
    end

    it "includes the #{encoding} BOM in invalid-input offsets" do
      invalid = encoding == "utf-32le" ? Bytes[0x00, 0xd8, 0x00, 0x00] : Bytes[0x00, 0x00, 0xd8, 0x00]
      bytes = Encoding.encode("A", encoding, bom: true) + invalid
      (0..bytes.size).each do |split|
        expect_raises(Encoding::InvalidByteSequenceError) do
          decode_chunks(bytes, "windows-1252", split, errors: Encoding::ErrorMode::Strict)
        end.offset.should eq(8)
      end
    end

    it "encodes replacement text in #{encoding}" do
      Encoding.encode("A💩\xff", encoding, replacement: "!").should eq(Encoding.encode("A💩!", encoding))
    end

    it "streams #{encoding} through IO adapters" do
      decoded = Encoding::DecoderIO.new(IO::Memory.new(input), encoding, bom: Encoding::BOMPolicy::Preserve)
      decoded.gets_to_end.should eq(text)
      output = IO::Memory.new
      encoded = Encoding::EncoderIO.new(output, encoding)
      text.to_slice.each { |byte| encoded.write(Bytes[byte]) }
      encoded.finish
      output.to_slice.should eq(input)
    end
  end
end
