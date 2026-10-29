require "./spec_helper"

private class BrokenOutput < IO
  def read(slice : Bytes) : Int32
    raise IO::Error.new("not readable")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("broken output")
  end
end

describe "conversion into an existing output" do
  it "appends chunks, BOMs, replacements, and final state into one buffer" do
    output = IO::Memory.new
    output << "prefix"
    decoder = Encoding::Decoder.new("windows-1252")
    decoder.feed(Bytes[0xff], output)
    decoder.finish(output)
    output.to_s.should eq("prefixÿ")

    output.clear
    encoder = Encoding::Encoder.new("utf-16le", bom: true, replacement: "!")
    encoder.feed(Bytes[0x41, 0xf0], output)
    encoder.finish(output)
    output.to_slice.should eq(Bytes[0xff, 0xfe, 0x41, 0x0, 0x21, 0x0])
    expect_raises(Encoding::StateError) { encoder.finish(output) }

    output.clear
    encoder = Encoding::Encoder.new("iso-2022-jp")
    encoder.feed("日本", output)
    encoder.finish(output)
    output.to_slice.should eq(Encoding.encode("日本", "iso-2022-jp"))
  end

  it "requires reset after an output error in either direction" do
    decoder = Encoding::Decoder.new(bom: :preserve)
    encoder = Encoding::Encoder.new
    expect_raises(IO::Error, "broken output") { decoder.feed(Bytes[0x41], BrokenOutput.new) }
    expect_raises(Encoding::StateError) { decoder.finish }
    decoder.reset.feed(Bytes[0x42]).should eq("B")
    expect_raises(IO::Error, "broken output") { encoder.feed("A", BrokenOutput.new) }
    expect_raises(Encoding::StateError) { encoder.finish }
    encoder.reset.feed("B").should eq(Bytes[0x42])
  end
end
