require "./spec_helper"

describe "BOM policies" do
  signatures = {"utf-8" => Bytes[0xef, 0xbb, 0xbf], "utf-16le" => Bytes[0xff, 0xfe], "utf-16be" => Bytes[0xfe, 0xff]}

  signatures.each do |encoding, signature|
    it "detects #{encoding} across every split and overrides the requested charset" do
      input = Encoding.encode("A💩", encoding, bom: true)
      (0..input.size).each do |split|
        decode_chunks(input, "windows-1252", split).should eq("A💩")
      end
      decoder = Encoding::Decoder.new("windows-1252")
      decoder.feed(signature).should eq("")
      decoder.encoding.name.should eq(Encoding.find(encoding).name)
      decoder.reset.encoding.name.should eq("windows-1252")
    end

    it "strips only one initial #{encoding} BOM and preserves embedded BOMs" do
      input = Encoding.encode("\uFEFFA\uFEFF", encoding, bom: true)
      Encoding.decode(input, encoding).should eq("\uFEFFA\uFEFF")
      Encoding.decode(input, encoding, bom: :strip).should eq("\uFEFFA\uFEFF")
      Encoding.decode(input, encoding, bom: :preserve).should eq("\uFEFF\uFEFFA\uFEFF")
      (0..input.size).each { |split| decode_chunks(input, encoding, split).should eq("\uFEFFA\uFEFF") }
    end

    it "emits a single #{encoding} BOM, including on an empty stream" do
      Encoding.encode("", encoding, bom: true).should eq(signature)
      Encoding.encode("", encoding).should eq(Bytes.empty)
      encoder = Encoding::Encoder.new(encoding, bom: true)
      encoder.feed("").should eq(signature)
      encoder.feed("").should eq(Bytes.empty)
      encoder.finish.should eq(Bytes.empty)
      encoder.reset.finish.should eq(signature)
    end
  end

  it "does not buffer an ordinary ASCII prefix" do
    Encoding::Decoder.new.feed(Bytes[0x41]).should eq("A")
    Encoding::Decoder.new("windows-1252", bom: :strip).feed(Bytes[0xef]).should eq("ï")
  end

  it "decodes incomplete BOMs using the requested codec at EOF" do
    Encoding.decode(Bytes[0xef, 0xbb]).should eq("�")
    Encoding.decode(Bytes[0xef, 0xbb], "windows-1252").should eq("ï»")
    Encoding.decode(Bytes[0xff], "windows-1252").should eq("ÿ")
    Encoding.decode(Bytes[0xfe], "utf-16be").should eq("�")
    Encoding.decode(Bytes.empty).should eq("")
  end

  it "can disable BOM overrides and rejects BOM emission for legacy codecs" do
    Encoding.decode(Bytes[0xff, 0xfe, 0x41, 0x0], "windows-1252", bom: :strip).should eq("ÿþA\0")
    Encoding.decode(Bytes[0xef, 0xbb, 0xbf], "windows-1252", bom: :preserve).should eq("ï»¿")
    Encoding.decode(Bytes[0xfe, 0xff, 0x0, 0x41], "utf-16le", bom: :strip).should eq("\uFFFE\u4100")
    expect_raises(ArgumentError) { Encoding::Encoder.new("gbk", bom: true) }
  end
end
