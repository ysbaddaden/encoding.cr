require "./spec_helper"

describe Encoding do
  it "converts ASCII through every real encoding" do
    Encoding.encodings.each do |encoding|
      next unless encoding.can_encode?
      text = "Hello\0\t\n~\\"
      encoded = encoding.encoder.feed(text)
      Encoding.decode(encoded, encoding.name).should eq(text)
      encoding.can_decode?.should be_true
    end
  end

  it "round trips every Unicode scalar through UTF-8 and both UTF-16 encodings" do
    text = String.build do |io|
      (0..0x10ffff).each { |cp| io << cp.chr unless (0xd800..0xdfff).includes?(cp) }
    end
    {"utf-8", "utf-16le", "utf-16be"}.each do |encoding|
      Encoding.decode(Encoding.encode(text, encoding, errors: :strict), encoding, errors: :strict).should eq(text)
    end
  end

  it "encodes known UTF-16 code units in the requested endianness" do
    Encoding.encode("A💩", "utf-16le").should eq(Bytes[0x41, 0x0, 0x3d, 0xd8, 0xa9, 0xdc])
    Encoding.encode("A💩", "utf-16be").should eq(Bytes[0x0, 0x41, 0xd8, 0x3d, 0xdc, 0xa9])
  end

  it "replaces malformed UTF-8 using maximal subparts and preserves ASCII" do
    {
      Bytes[0xf0, 0x90, 0x80]       => "�",
      Bytes[0xe0, 0x80, 0x80]       => "���",
      Bytes[0xed, 0xa0, 0x80]       => "���",
      Bytes[0xf4, 0x90, 0x80, 0x80] => "����",
      Bytes[0xf0, 0xc3, 0x80, 0x2a] => "�À*",
      Bytes[0xc0, 0x0, 0xff]        => "�\0�",
    }.each do |input, expected|
      Encoding.decode(input).should eq(expected)
      (0..input.size).each { |split| decode_chunks(input, "utf-8", split).should eq(expected) }
    end
  end

  it "consumes an unfinished UTF-16 surrogate and partial unit as one error" do
    Encoding.decode(Bytes[0x0, 0xd8, 0x0], "utf-16le").should eq("�")
    Encoding.decode(Bytes[0xd8, 0x0, 0x0], "utf-16be").should eq("�")
    Encoding.decode(Bytes[0x0, 0xd8, 0x0, 0xd8], "utf-16le").should eq("��")
    Encoding.decode(Bytes[0x0, 0x0, 0x0], "utf-16le").should eq("\0�")
  end

  it "supports custom and empty decoder replacements" do
    Encoding.decode(Bytes[0xc0, 0xc0], replacement: "[bad]").should eq("[bad][bad]")
    Encoding.decode(Bytes[0xff, 0x41], replacement: "").should eq("A")
    Encoding.decode(Bytes[0xff], replacement: "💩").should eq("💩")
    expect_raises(ArgumentError) { Encoding::Decoder.new(replacement: String.new(Bytes[0xff])) }
  end

  it "replaces unrepresentable characters without recursive fallback" do
    Encoding.encode("A💩B", "windows-1252").should eq(Bytes[0x41, 0x3f, 0x42])
    Encoding.encode("💩", "windows-1252", replacement: "€!").should eq(Bytes[0x80, 0x21])
    Encoding.encode("A💩B", "windows-1252", replacement: "").should eq(Bytes[0x41, 0x42])
    expect_raises(ArgumentError) { Encoding::Encoder.new("windows-1252", replacement: "💩") }
    expect_raises(ArgumentError) { Encoding::Encoder.new(replacement: String.new(Bytes[0xff])) }
    expect_raises(ArgumentError) { Encoding::Encoder.new("iso-2022-jp", replacement: "\e") }
  end

  it "uses encoder replacements for malformed UTF-8 input, even for Unicode destinations" do
    Encoding.encode(Bytes[0xf0, 0x80, 0x41]).should eq("??A".to_slice)
    Encoding.encode(Bytes[0xf0, 0x90], "utf-16le", replacement: "!").should eq(Bytes[0x21, 0x0])
    expect_raises(Encoding::InvalidByteSequenceError) { Encoding.encode(Bytes[0xff], errors: :strict) }
  end

  it "encodes replacements in the current ISO-2022-JP state" do
    input = "日💩本"
    encoded = Encoding.encode(input, "iso-2022-jp", replacement: "代")
    Encoding.decode(encoded, "iso-2022-jp").should eq("日代本")
    encoded = Encoding.encode(input, "iso-2022-jp")
    Encoding.decode(encoded, "iso-2022-jp").should eq("日?本")
    Encoding.decode(Encoding.encode("¥💩", "iso-2022-jp"), "iso-2022-jp").should eq("¥?")
  end

  it "reports absolute byte offsets across chunks and after a BOM" do
    decoder = Encoding::Decoder.new(errors: :strict)
    decoder.feed(Bytes[0xef])
    decoder.feed(Bytes[0xbb, 0xbf, 0x41, 0xe2])
    error = expect_raises(Encoding::InvalidByteSequenceError) { decoder.feed(Bytes[0x21]) }
    error.offset.should eq(4)
    error.encoding.should eq("UTF-8")
    decoder = Encoding::Decoder.new("utf-16le", errors: :strict)
    decoder.feed(Bytes[0x41, 0x0, 0x0])
    expect_raises(Encoding::InvalidByteSequenceError) { decoder.finish }.offset.should eq(2)
    encoder = Encoding::Encoder.new("windows-1252", errors: :strict)
    encoder.feed("€")
    error = expect_raises(Encoding::UndefinedConversionError) { encoder.feed("💩") }
    error.offset.should eq(3)
    error.encoding.should eq("windows-1252")
  end

  it "requires reset after failure or finalization and resets offsets and state" do
    decoder = Encoding::Decoder.new(errors: :strict, bom: :preserve)
    expect_raises(Encoding::InvalidByteSequenceError) { decoder.feed(Bytes[0xff]) }
    expect_raises(Encoding::StateError) { decoder.feed(Bytes[0x41]) }
    decoder.reset.feed(Bytes[0x42]).should eq("B")
    decoder.finish.should eq("")
    expect_raises(Encoding::StateError) { decoder.finish }
    decoder.reset.finish.should eq("")
    encoder = Encoding::Encoder.new("windows-1252", errors: :strict)
    expect_raises(Encoding::UndefinedConversionError) { encoder.feed("💩") }
    expect_raises(Encoding::StateError) { encoder.finish }
    encoder.reset.feed("B").should eq(Bytes[0x42])
    encoder.finish.should eq(Bytes.empty)
    expect_raises(Encoding::StateError) { encoder.feed("") }
    encoder.reset.finish.should eq(Bytes.empty)
  end

  it "flushes ISO-2022-JP only on finish and resets to ASCII" do
    encoder = Encoding::Encoder.new("iso-2022-jp")
    encoder.feed("¥").should eq(Bytes[0x1b, 0x28, 0x4a, 0x5c])
    encoder.feed("").should eq(Bytes.empty)
    encoder.finish.should eq(Bytes[0x1b, 0x28, 0x42])
    encoder.reset.feed("A").should eq(Bytes[0x41])
  end

  it "implements the replacement pseudo-decoder, but no encoder" do
    descriptor = Encoding.find("iso-2022-kr")
    descriptor.name.should eq("replacement")
    descriptor.can_encode?.should be_false
    decoder = descriptor.decoder(bom: :preserve)
    decoder.feed(Bytes.empty).should eq("")
    decoder.feed(Bytes[0x41]).should eq("�")
    decoder.feed(Bytes[0x42]).should eq("")
    decoder.finish.should eq("")
    decoder.reset.finish.should eq("")
    expect_raises(Encoding::UnsupportedEncodingError) { descriptor.encoder }
    expect_raises(Encoding::InvalidByteSequenceError) { Encoding.decode(Bytes[0x41], "replacement", errors: :strict) }
  end

  it "rejects unknown, unsupported, and Unicode-lookalike labels" do
    {"", "utf-7", "\vutf-8", "utf-8\u00A0", "Koi8-r", "iso-8859-12"}.each do |label|
      expect_raises(Encoding::UnknownEncodingError) { Encoding.find(label) }
    end
    Encoding.find("ascii").name.should eq("windows-1252")
    Encoding.find("unicode").name.should eq("UTF-16LE")
    Encoding.find("iso-8859-9").name.should eq("windows-1254")
  end

  it "handles large streams consistently across arbitrary chunks" do
    random = Random.new(941)
    {"utf-8", "utf-16le", "gb18030", "big5", "shift_jis", "euc-jp", "euc-kr", "iso-2022-jp"}.each do |encoding|
      input = Bytes.new(16384) { random.rand(256).to_u8 }
      expected = Encoding.decode(input, encoding)
      decoder = Encoding::Decoder.new(encoding)
      actual = String.build do |output|
        offset = 0
        while offset < input.size
          count = Math.min(random.rand(1..31), input.size - offset)
          output << decoder.feed(input[offset, count])
          offset += count
        end
        output << decoder.finish
      end
      actual.should eq(expected)
    end
  end
  it "owns incomplete tokens when the caller reuses its input buffer" do
    decoder = Encoding::Decoder.new(bom: :preserve, errors: :strict)
    buffer = Bytes[0xf0, 0x9f]
    decoder.feed(buffer).should eq("")
    buffer.fill(0)
    decoder.feed(Bytes[0x98]).should eq("")
    decoder.feed(Bytes.empty).should eq("")
    decoder.feed(Bytes[0x80, 0x41, 0xe2]).should eq("😀A")
    decoder.feed(Bytes[0x82, 0xac]).should eq("€")
    decoder.finish.should eq("")
  end
  it "reuses multicharacter replacements across feeds and resets" do
    {"utf-8", "utf-16le", "utf-16be", "windows-1252", "gb18030", "big5", "shift_jis", "euc-jp", "euc-kr", "iso-2022-jp"}.each do |encoding|
      encoder = Encoding::Encoder.new(encoding, replacement: "[?]")
      2.times do
        output = IO::Memory.new
        output.write(encoder.feed(Bytes[0x41, 0xff]))
        output.write(encoder.feed(Bytes[0xff, 0x42]))
        output.write(encoder.finish)
        Encoding.decode(output.to_slice, encoding).should eq("A[?][?]B")
        encoder.reset
      end
    end
  end
end
