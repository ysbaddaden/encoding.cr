require "./spec_helper"

describe "bulk ASCII conversion" do
  it "writes UTF-16 spans across output buffer boundaries in both byte orders" do
    {"utf-16le", "utf-16be"}.each do |name|
      {0, 1, 127, 128, 129, 255, 256, 257}.each do |size|
        input = Bytes.new(size) { |i| (i % 128).to_u8 }
        expected = Bytes.new(size * 2) do |i|
          i % 2 == (name == "utf-16le" ? 0 : 1) ? input[i // 2] : 0_u8
        end
        Encoding.encode(input, name, errors: :strict).should eq(expected)
        (0..size).each do |split|
          encoder = Encoding::Encoder.new(name, errors: :strict)
          output = IO::Memory.new
          encoder.feed(input[0, split], output)
          encoder.feed(input[split..], output)
          encoder.finish(output)
          output.to_slice.should eq(expected)
        end
      end
    end
  end

  it "preserves absolute offsets after long spans and split tokens" do
    decoder = Encoding::Decoder.new(errors: :strict, bom: :preserve)
    decoder.feed(("A" * 2048).to_slice).should eq("A" * 2048)
    decoder.feed(Bytes[0xe2]).should eq("")
    error = expect_raises(Encoding::InvalidByteSequenceError) { decoder.feed(Bytes[0x41]) }
    error.offset.should eq(2048)
    encoder = Encoding::Encoder.new("windows-1252", errors: :strict)
    encoder.feed("A" * 2048)
    error = expect_raises(Encoding::UndefinedConversionError) { encoder.feed("😀") }
    error.offset.should eq(2048)
  end

  it "handles ISO-2022-JP Roman spans, controls, and consecutive escapes" do
    bytes = Bytes[0x1b, 0x28, 0x4a, 0x5c, 0x41, 0x42, 0x7e, 0x1b, 0x28, 0x42, 0x5c, 0x7e]
    text = "¥AB‾\\~"
    Encoding.decode(bytes, "iso-2022-jp").should eq(text)
    Encoding.encode(text, "iso-2022-jp").should eq(bytes)
    Encoding.decode(Bytes[0x1b, 0x28, 0x42, 0x41, 0x1b, 0x28, 0x42], "iso-2022-jp").should eq("A")
    Encoding.encode("A\eB\u000eC\u000fD", "iso-2022-jp").should eq("A?B?C?D".to_slice)
  end
end

describe "validated UTF-8 spans" do
  it "resumes spans after maximal-subpart replacements" do
    prefix = "é日😀\uFEFF" * 4
    malformed = (prefix + "\xed\xa0\x80" + "A😀").to_slice
    Encoding.decode(malformed).should eq(prefix + "���A😀")
    Encoding.encode(malformed).should eq((prefix + "???A😀").to_slice)
    (0..malformed.size).each do |split|
      decode_chunks(malformed, "utf-8", split).should eq(prefix + "���A😀")
    end
  end

  it "reports the first malformed byte after multibyte spans in strict mode" do
    prefix = "é日😀" * 32
    input = (prefix + "\xf4\x90\x80\x80").to_slice
    expect_raises(Encoding::InvalidByteSequenceError) { Encoding.decode(input, errors: :strict) }.offset.should eq(prefix.bytesize)
    expect_raises(Encoding::InvalidByteSequenceError) { Encoding.encode(input, errors: :strict) }.offset.should eq(prefix.bytesize)
  end
end
