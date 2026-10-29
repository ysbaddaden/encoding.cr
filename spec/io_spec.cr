require "./spec_helper"

# Enforces short reads independently of the adapter's requested buffer size.
private class ShortReader < IO
  @source : IO::Memory
  @closed = false

  def initialize(bytes : Bytes, @limit : Int32 = 1)
    @source = IO::Memory.new(bytes)
  end

  def read(slice : Bytes) : Int32
    @source.read(slice[0, Math.min(slice.size, @limit)])
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end

  def close : Nil
    @closed = true
  end

  def closed? : Bool
    @closed
  end
end

private class FailingWriter < IO
  def write(slice : Bytes) : Nil
    raise IO::Error.new("write failed")
  end

  def read(slice : Bytes) : Int32
    0
  end
end

private class FailingFlusher < IO::Memory
  def flush : Nil
    raise IO::Error.new("flush failed")
  end
end

describe Encoding::DecoderIO do
  it "reads split BOMs and characters through a one-byte output buffer" do
    source = ShortReader.new(Encoding.encode("A日本💩", "utf-16be", bom: true))
    decoder = Encoding::DecoderIO.new(source, "windows-1252")
    decoder.read(Bytes.empty).should eq(0)
    result = IO::Memory.new
    buffer = Bytes.new(1)
    while (count = decoder.read(buffer)) > 0
      result.write(buffer[0, count])
    end
    result.to_s.should eq("A日本💩")
    decoder.read(buffer).should eq(0)
    decoder.close
    decoder.closed?.should be_true
    source.closed?.should be_false
    expect_raises(IO::Error) { decoder.read(buffer) }
  end

  it "finalizes truncated input in replacement and strict modes" do
    decoder = Encoding::DecoderIO.new(ShortReader.new(Bytes[0x41, 0xe2, 0x82]))
    decoder.gets_to_end.should eq("A�")
    decoder = Encoding::DecoderIO.new(ShortReader.new(Bytes[0x41, 0xe2, 0x82]), errors: :strict)
    expect_raises(Encoding::InvalidByteSequenceError) { decoder.gets_to_end }.offset.should eq(1)
    expect_raises(Encoding::StateError) { decoder.read(Bytes.new(1)) }
  end

  it "handles large input and custom replacements" do
    bytes = Bytes.new(16385, 0xff)
    decoder = Encoding::DecoderIO.new(IO::Memory.new(bytes), "utf-8", replacement: "日本", bom: :preserve)
    decoder.gets_to_end.should eq("日本" * bytes.size)
  end

  it "honors underlying ownership and rejects writing" do
    source = ShortReader.new(Bytes[0x41])
    decoder = Encoding::DecoderIO.new(source, close_underlying: true)
    expect_raises(IO::Error) { decoder.write(Bytes[0x41]) }
    decoder.close
    decoder.close
    source.closed?.should be_true
  end
end

describe Encoding::EncoderIO do
  it "accepts UTF-8 split at every byte and emits a BOM only once" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, "utf-16le", bom: true)
    "A日本💩".to_slice.each { |byte| encoder.write(Bytes[byte]) }
    encoder.flush
    encoder.finish
    encoder.finish
    output.to_slice.should eq(Encoding.encode("A日本💩", "utf-16le", bom: true))
    encoder.close
    encoder.close
    output.closed?.should be_false
    expect_raises(IO::Error) { encoder.write(Bytes[0x41]) }
  end

  it "does not finalize ISO-2022-JP on flush" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, "iso-2022-jp")
    encoder << "日"
    before = output.to_slice.dup
    encoder.flush
    output.to_slice.should eq(before)
    encoder << "本"
    encoder.close
    output.to_slice.should eq(Encoding.encode("日本", "iso-2022-jp"))
  end

  it "processes large writes in bounded chunks" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, "gb18030")
    encoder << "A日本💩" * 10000
    encoder.finish
    output.to_slice.should eq(Encoding.encode("A日本💩" * 10000, "gb18030"))
    expect_raises(Encoding::StateError) { encoder << "A" }
  end

  it "reports finalization errors and still closes owned IO" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, errors: :strict, close_underlying: true)
    encoder.write(Bytes[0xf0])
    expect_raises(Encoding::InvalidByteSequenceError) { encoder.close }
    encoder.closed?.should be_true
    output.closed?.should be_true
    encoder.close
  end

  it "uses custom replacement for incomplete UTF-8 on close" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, "windows-1252", replacement: "!")
    encoder.write(Bytes[0xf0])
    encoder.close
    output.to_s.should eq("!")
  end

  it "fails permanently after downstream write errors" do
    encoder = Encoding::EncoderIO.new(FailingWriter.new)
    expect_raises(IO::Error, "write failed") { encoder << "A" }
    expect_raises(Encoding::StateError) { encoder << "B" }
    expect_raises(Encoding::StateError) { encoder.finish }
    encoder.close
    encoder.closed?.should be_true
  end

  it "fails permanently after downstream flush errors" do
    encoder = Encoding::EncoderIO.new(FailingFlusher.new)
    expect_raises(IO::Error, "flush failed") { encoder.flush }
    expect_raises(Encoding::StateError) { encoder << "A" }
    expect_raises(Encoding::StateError) { encoder.flush }
    encoder.close
  end

  it "rejects reading and honors underlying IO ownership" do
    output = IO::Memory.new
    encoder = Encoding::EncoderIO.new(output, close_underlying: true)
    expect_raises(IO::Error) { encoder.read(Bytes.new(1)) }
    encoder.close
    output.closed?.should be_true
  end
end
