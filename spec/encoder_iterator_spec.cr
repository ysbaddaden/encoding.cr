require "./spec_helper"

describe Encoding::Encoder do
  it "handles every UTF-8 split, empty feeds, and NUL across destinations" do
    samples = {
      {"A\0é日😀Z".to_slice, "A\0é日😀Z"},
      {"A\0\xed\xa0\x80日\xe2\x82Z\xff".to_slice, "A\0???日?Z?"},
      {"A\0日\xf0\x9f\x98".to_slice, "A\0日?"},
      {"A\xc2".to_slice, "A?"},
      {"A\xe2".to_slice, "A?"},
      {"A\xe2\x82".to_slice, "A?"},
      {"A\xf0".to_slice, "A?"},
      {"A\xf0\x9f".to_slice, "A?"},
      {"\xe0\x80\xaf\xf4\x90\x80\x80".to_slice, "???????"},
    }
    {"utf-8", "utf-16le", "windows-1252", "gb18030", "shift_jis", "iso-2022-jp"}.each do |name|
      samples.each do |input, recovered|
        expected = Encoding.encode(recovered, name)
        (0..input.size).each do |split|
          encoder = Encoding::Encoder.new(name)
          output = IO::Memory.new
          encoder.feed(Bytes.empty, output)
          encoder.feed(input[0, split], output)
          encoder.feed(Bytes.empty, output)
          encoder.feed(input[split..], output)
          encoder.feed(Bytes.empty, output)
          encoder.finish(output)
          output.to_slice.should eq(expected)
        end
      end
    end
  end

  it "reports absolute malformed, truncated, and unrepresentable offsets at every split" do
    {"AB\0日\xe2\x82Z", "AB\0日\xf0\x9f"}.each do |text|
      input = text.to_slice
      (0..input.size).each do |split|
        encoder = Encoding::Encoder.new(errors: :strict)
        error = expect_raises(Encoding::InvalidByteSequenceError) do
          encoder.feed(input[0, split])
          encoder.feed(Bytes.empty)
          encoder.feed(input[split..])
          encoder.finish
        end
        error.offset.should eq(6)
      end
    end
    input = "AB\0é😀".to_slice
    (0..input.size).each do |split|
      encoder = Encoding::Encoder.new("windows-1252", errors: :strict)
      expect_raises(Encoding::UndefinedConversionError) do
        encoder.feed(input[0, split])
        encoder.feed(Bytes.empty)
        encoder.feed(input[split..])
        encoder.finish
      end.offset.should eq(5)
    end
  end

  it "owns incomplete suffixes when callers reuse buffers" do
    encoder = Encoding::Encoder.new
    buffer = Bytes[0x41, 0xf0, 0x9f]
    encoder.feed(buffer).should eq(Bytes[0x41])
    buffer.fill(0xff_u8)
    encoder.feed(Bytes.empty).should be_empty
    encoder.feed(Bytes[0x98, 0x80, 0x0]).should eq("😀\0".to_slice)
    encoder.finish.should be_empty
    # The same input helper also serves legacy readers.
    decoder = Encoding::Decoder.new("utf-16le", bom: :preserve)
    buffer = Bytes[0x41, 0x0, 0x3d]
    decoder.feed(buffer).should eq("A")
    buffer.fill(0xff_u8)
    decoder.feed(Bytes[0xd8, 0x0, 0xde]).should eq("😀")
    decoder.finish.should eq("")
  end

  it "resets pending bytes, offsets, failure, BOM, and destination state" do
    encoder = Encoding::Encoder.new(errors: :strict, bom: true)
    encoder.feed(Bytes[0xf0])
    encoder.reset
    encoder.feed("A").should eq(Bytes[0xef, 0xbb, 0xbf, 0x41])
    encoder.finish.should be_empty
    encoder.reset
    expect_raises(Encoding::InvalidByteSequenceError) { encoder.feed(Bytes[0xff]) }.offset.should eq(0)
    encoder.reset
    encoder.feed("B").should eq(Bytes[0xef, 0xbb, 0xbf, 0x42])
    encoder.finish
  end

  it "preserves ISO-2022-JP transitions and live replacement state at every split" do
    input = "日😀¥A\\‾\0\e本\xe2\x82".to_slice
    {"代", "代?", "¥", ""}.each do |replacement|
      expected = Encoding.encode(input, "iso-2022-jp", replacement: replacement)
      (0..input.size).each do |split|
        encoder = Encoding::Encoder.new("iso-2022-jp", replacement: replacement)
        output = IO::Memory.new
        encoder.feed(input[0, split], output)
        encoder.feed(Bytes.empty, output)
        encoder.feed(input[split..], output)
        encoder.finish(output)
        output.to_slice.should eq(expected)
        Encoding.decode(output.to_slice, "iso-2022-jp", errors: :strict).should eq(
          "日#{replacement}¥A\\‾\0#{replacement}本#{replacement}")
        encoder.reset
        encoder.feed("A").should eq(Bytes[0x41])
        encoder.finish.should be_empty
      end
    end
  end
end
