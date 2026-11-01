require "./spec_helper"
require "../src/encoding/patch"

describe "encoding/patch" do
  it "converts strings using stdlib signatures" do
    String.new(Bytes[0x63, 0x61, 0x66, 0xe9], "windows-1252").should eq("café")
    "café".encode("windows-1252").should eq(Bytes[0x63, 0x61, 0x66, 0xe9])
    String.new(Bytes[0xef, 0xbb, 0xbf, 0x41], "UTF-8").should eq("\uFEFFA")
  end

  it "raises or skips according to invalid" do
    expect_raises(ArgumentError) { String.new(Bytes[0xff], "UTF-8") }
    String.new(Bytes[0xff, 0x41], "UTF-8", :skip).should eq("A")
    expect_raises(ArgumentError) { "💩".encode("windows-1252") }
    "A💩B".encode("windows-1252", :skip).should eq(Bytes[0x41, 0x42])
    expect_raises(ArgumentError) { "A".encode("UTF-8", :replace) }
  end

  it "supports IO text operations and raw bytes" do
    io = IO::Memory.new(Bytes[0xe9, 0x0a, 0x41])
    io.set_encoding("windows-1252")
    io.gets.should eq("é")
    io.read_char.should eq('A')
    io.read_char.should be_nil

    output = IO::Memory.new
    output.set_encoding("utf-16le")
    output << "A💩"
    output.to_slice.should eq(Encoding.encode("A💩", "utf-16le"))
    output.to_s.should eq("A💩")
    copy = IO::Memory.new
    output.to_s(copy)
    copy.to_s.should eq("A💩")
  end

  it "finalizes decoding at EOF and handles skipped input" do
    io = IO::Memory.new(Bytes[0x41, 0x00, 0x42])
    io.set_encoding("utf-16le")
    expect_raises(ArgumentError) { io.gets_to_end }
    io = IO::Memory.new(Bytes[0xff, 0x41])
    io.set_encoding("UTF-8", :skip)
    io.gets_to_end.should eq("A")
  end

  it "finalizes stateful output when changing encodings" do
    io = IO::Memory.new
    io.set_encoding("iso-2022-jp")
    io << "日本"
    io.set_encoding("UTF-8")
    io.to_slice.should eq(Encoding.encode("日本", "iso-2022-jp"))
  end

  it "keeps partial characters across IO buffers and writes" do
    text = "A" * 4095 + "💩" + "B"
    input = IO::Memory.new(text.to_slice)
    input.set_encoding("UTF-8", :skip)
    input.gets_to_end.should eq(text)

    output = IO::Memory.new
    output.set_encoding("utf-16be")
    utf8 = "💩".to_slice
    output.write_string(utf8[0, 2])
    output.write_string(utf8[2, 2])
    output.to_slice.should eq(Encoding.encode("💩", "utf-16be"))
  end

  it "keeps UTF-16 helpers available" do
    String.from_utf16("A💩".to_utf16).should eq("A💩")
  end
end

# Copied from Crystal spec/std/{string_spec,io/io_spec,io/buffered_spec,io/memory_spec}.cr.
# Adapted helper names, fixture paths, byte literal formatting, exception
# messages, and the outer without_iconv guards for this shard.
# UCS-2LE passthrough cases use UTF-16LE.
require "base64"
require "big"
require "socket"
require "io/buffered"

# This is a non-optimized version of IO::Memory so we can test
# raw IO. Optimizations for specific IOs are tested separately
# (for example in buffered_io_spec)
private class PatchSimpleIOMemory < IO
  getter buffer : UInt8*
  getter bytesize : Int32
  @capacity : Int32
  @pos : Int32
  @max_read : Int32?

  def initialize(capacity = 64, @max_read = nil)
    @buffer = GC.malloc_atomic(capacity.to_u32).as(UInt8*)
    @bytesize = 0
    @capacity = capacity
    @pos = 0
  end

  def self.new(string : String, max_read = nil)
    io = new(string.bytesize, max_read: max_read)
    io << string
    io
  end

  def self.new(bytes : Bytes, max_read = nil)
    io = new(bytes.size, max_read: max_read)
    io.write(bytes)
    io
  end

  def read(slice : Bytes)
    count = slice.size
    count = Math.min(count, @bytesize - @pos)
    if max_read = @max_read
      count = Math.min(count, max_read)
    end
    slice.copy_from(@buffer + @pos, count)
    @pos += count
    count
  end

  def write(slice : Bytes) : Nil
    count = slice.size
    new_bytesize = bytesize + count
    if new_bytesize > @capacity
      resize_to_capacity(Math.pw2ceil(new_bytesize))
    end

    slice.copy_to(@buffer + @bytesize, count)
    @bytesize += count
  end

  def to_slice
    Slice.new(@buffer, @bytesize)
  end

  def to_s
    String.new @buffer, @bytesize
  end

  def rewind
    @pos = 0
    self
  end

  private def resize_to_capacity(capacity)
    @capacity = capacity
    @buffer = GC.realloc(@buffer, @capacity)
  end
end

private class PatchBufferedWrapper < IO
  include IO::Buffered

  getter called_unbuffered_read

  @io : IO
  @called_unbuffered_read : Bool

  def initialize(@io)
    @called_unbuffered_read = false
  end

  def self.new(io, &)
    buffered_io = new(io)
    yield buffered_io
    buffered_io.flush
    io
  end

  private def unbuffered_read(slice : Bytes) : Int32
    @called_unbuffered_read = true
    @io.read(slice)
  end

  private def unbuffered_write(slice : Bytes) : Nil
    @io.write(slice)
  end

  private def unbuffered_flush
    @io.flush
  end

  def fd
    @io.fd
  end

  private def unbuffered_close
    @io.close
  end

  def closed?
    @io.closed?
  end

  private def unbuffered_rewind
    @io.rewind
  end
end

describe "stdlib String encoding compatibility" do
  describe "encode" do
    it "encodes" do
      bytes = "Hello".encode("UTF-16LE")
      bytes.should eq Bytes[0x48, 0x00, 0x65, 0x00, 0x6c, 0x00, 0x6c, 0x00, 0x6f, 0x00]
    end

    # Requires Big5-HKSCS encoding beyond the WHATWG Big5 encoder.
    pending "flushes the shift state (#11992)" do
      "\u{00CA}".encode("BIG5-HKSCS").should eq(Bytes[0x88, 0x66])
      "\u{00CA}\u{0304}".encode("BIG5-HKSCS").should eq(Bytes[0x88, 0x62])
    end

    it "raises if wrong encoding" do
      expect_raises ArgumentError, "Unknown encoding: \"FOO\"" do
        "Hello".encode("FOO")
      end
    end

    it "raises if wrong encoding with skip" do
      expect_raises ArgumentError, "Unknown encoding: \"FOO\"" do
        "Hello".encode("FOO", invalid: :skip)
      end
    end

    it "raises if illegal byte sequence" do
      expect_raises ArgumentError, "Malformed byte sequence" do
        "\xff".encode("EUC-JP")
      end
    end

    it "doesn't raise on invalid byte sequence" do
      "好\xff是".encode("EUC-JP", invalid: :skip).should eq(Bytes[0xb9, 0xa5, 0xc0, 0xa7])
    end

    it "raises if incomplete byte sequence" do
      expect_raises ArgumentError, "Malformed byte sequence" do
        "好".byte_slice(0, 1).encode("EUC-JP")
      end
    end

    it "doesn't raise if incomplete byte sequence" do
      ("好".byte_slice(0, 1) + "是").encode("EUC-JP", invalid: :skip).should eq(Bytes[0xc0, 0xa7])
    end

    it "decodes" do
      bytes = "Hello".encode("UTF-16LE")
      String.new(bytes, "UTF-16LE").should eq("Hello")
    end

    it "decodes with shift state" do
      String.new(Bytes[0x88, 0x66], "BIG5-HKSCS").should eq("\u{00CA}")
      String.new(Bytes[0x88, 0x62], "BIG5-HKSCS").should eq("\u{00CA}\u{0304}")
    end

    it "decodes with skip" do
      bytes = Bytes[0xba, 0xc3, 0xff, 0xca, 0xc7]
      String.new(bytes, "EUC-JP", invalid: :skip).should eq("挫頁")
    end
  end
end

describe "stdlib IO encoding compatibility" do
  describe "encoding" do
    describe "decode" do
      it "gets_to_end" do
        str = "Hello world" * 200
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets_to_end.should eq(str)
      end

      it "gets" do
        str = "Hello world\r\nFoo\nBar"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets.should eq("Hello world")
        io.gets.should eq("Foo")
        io.gets.should eq("Bar")
        io.gets.should be_nil
      end

      it "gets with chomp = false" do
        str = "Hello world\r\nFoo\nBar"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(chomp: false).should eq("Hello world\r\n")
        io.gets(chomp: false).should eq("Foo\n")
        io.gets(chomp: false).should eq("Bar")
        io.gets(chomp: false).should be_nil
      end

      it "gets big string" do
        str = "Hello\nWorld\n" * 10_000
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        10_000.times do |i|
          io.gets.should eq("Hello")
          io.gets.should eq("World")
        end
      end

      it "gets big EUC-JP string" do
        2.times do
          str = ("好我是人\n" * 1000).encode("EUC-JP")
          io = PatchSimpleIOMemory.new(str)
          io.set_encoding("EUC-JP")
          1000.times do
            io.gets.should eq("好我是人")
          end
        end
      end

      it "does gets on unicode with char and limit without off-by-one" do
        io = PatchSimpleIOMemory.new("test\nabc".encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets('a', 5).should eq("test\n")
        io = PatchSimpleIOMemory.new("test\nabc".encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets('a', 6).should eq("test\na")
      end

      it "gets with limit" do
        str = "Hello\nWorld\n"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(3).should eq("Hel")
      end

      it "gets with limit (small, no newline)" do
        str = "Hello world" * 10_000
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(3).should eq("Hel")
      end

      it "gets with non-ascii" do
        str = "你好我是人"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets('人').should eq("你好我是人")
      end

      it "gets with non-ascii and chomp: false" do
        str = "你好我是人"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets('人', chomp: true).should eq("你好我是")
      end

      it "gets with limit (big)" do
        str = "Hello world" * 10_000
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(20_000).should eq(str[0, 20_000])
      end

      it "gets with string delimiter" do
        str = "Hello world\nFoo\nBar"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets("wo").should eq("Hello wo")
        io.gets("oo").should eq("rld\nFoo")
        io.gets("xx").should eq("\nBar")
        io.gets("zz").should be_nil
      end

      it "reads char" do
        str = "Hello world"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        str.each_char do |char|
          io.read_char.should eq(char)
        end
        io.read_char.should be_nil
      end

      it "reads utf8 byte" do
        str = "Hello world"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        str.each_byte do |byte|
          io.read_utf8_byte.should eq(byte)
        end
        io.read_utf8_byte.should be_nil
      end

      it "reads utf8" do
        io = IO::Memory.new("好".encode("EUC-JP"))
        io.set_encoding("EUC-JP")

        buffer = uninitialized UInt8[1024]
        bytes_read = io.read_utf8(buffer.to_slice) # => 3
        bytes_read.should eq(3)
        buffer.to_slice[0, bytes_read].to_a.should eq("好".bytes)
      end

      it "raises on incomplete byte sequence" do
        io = PatchSimpleIOMemory.new("好".byte_slice(0, 1))
        io.set_encoding("EUC-JP")
        expect_raises ArgumentError, "Malformed byte sequence" do
          io.read_char
        end
      end

      it "says invalid byte sequence" do
        io = PatchSimpleIOMemory.new(Slice.new(1, 255_u8))
        io.set_encoding("EUC-JP")
        message = "Malformed byte sequence"
        expect_raises(ArgumentError, message) { io.read_char }
      end

      it "skips invalid byte sequences" do
        string = String.build do |str|
          str.write "好".encode("EUC-JP")
          str.write_byte 255_u8
          str.write "是".encode("EUC-JP")
        end
        io = PatchSimpleIOMemory.new(string)
        io.set_encoding("EUC-JP", invalid: :skip)
        io.read_char.should eq('好')
        io.read_char.should eq('是')
        io.read_char.should be_nil
      end

      it "says invalid 'invalid' option" do
        io = PatchSimpleIOMemory.new
        expect_raises ArgumentError, "Valid values for `invalid` option are `nil` and `:skip`, not :foo" do
          io.set_encoding("EUC-JP", invalid: :foo)
        end
      end

      it "says invalid encoding" do
        io = PatchSimpleIOMemory.new("foo")
        io.set_encoding("FOO")
        expect_raises ArgumentError, "Unknown encoding: \"FOO\"" do
          io.gets_to_end
        end
      end

      it "sets encoding to utf-8 and stays as UTF-8" do
        io = PatchSimpleIOMemory.new(Base64.decode_string("ey8qx+Tl8fwg7+Dw4Ozl8vD7IOLo5+jy4CovfQ=="))
        io.set_encoding("utf-8")
        io.encoding.should eq("UTF-8")
      end

      it "sets encoding to utf8 and stays as UTF-8" do
        io = PatchSimpleIOMemory.new(Base64.decode_string("ey8qx+Tl8fwg7+Dw4Ozl8vD7IOLo5+jy4CovfQ=="))
        io.set_encoding("utf8")
        io.encoding.should eq("UTF-8")
      end

      it "handles long lines correctly with invalid: :skip" do
        # Using both ASCII characters and a 26-byte Unicode characters to
        # ensure we hit as many byte boundaries inside the Unicode characters
        # as we can to get sufficient confidence in this test.
        text = "test string 👩🏾‍🤝‍👨🏻" * 10240
        io = IO::Memory.new
        io.set_encoding "UTF-8", invalid: :skip
        io << text

        io.bytesize.should eq text.bytesize
        io.to_slice.should eq text.to_slice
      end

      it "does skips when converting to UTF-8" do
        io = PatchSimpleIOMemory.new(Base64.decode_string("ey8qx+Tl8fwg7+Dw4Ozl8vD7IOLo5+jy4CovfQ=="))
        io.set_encoding("UTF-8", invalid: :skip)
        io.gets_to_end.should eq "{/*  */}"
      end

      it "decodes incomplete multibyte sequence with skip (#3285)" do
        bytes = Bytes[0xc3, 0xe5, 0xed, 0xe5, 0xf0, 0xe0, 0xf6, 0xe8, 0xff, 0x20, 0xf1, 0xea, 0xf0, 0xe8, 0xef, 0xf2, 0xe0, 0x20, 0x30, 0x2e, 0x30, 0x31, 0x32, 0x36, 0x20, 0xf1, 0xe5, 0xea, 0xf3, 0xed, 0xe4, 0x0a]
        m = IO::Memory.new(bytes)
        m.set_encoding("UTF-8", invalid: :skip)
        m.gets_to_end.should eq("  0.0126 \n")
      end

      it "decodes incomplete multibyte sequence with skip (2) (#3285)" do
        str = File.read(File.join(__DIR__, "fixtures", "stdlib", "io_data_incomplete_multibyte_sequence.txt"))
        m = IO::Memory.new(Base64.decode_string str)
        m.set_encoding("UTF-8", invalid: :skip)
        m.gets_to_end.bytesize.should eq(4277)
      end

      it "decodes incomplete multibyte sequence with skip (3) (#3285)" do
        str = File.read(File.join(__DIR__, "fixtures", "stdlib", "io_data_incomplete_multibyte_sequence_2.txt"))
        m = IO::Memory.new(Base64.decode_string str)
        m.set_encoding("UTF-8", invalid: :skip)
        m.gets_to_end.bytesize.should eq(8977)
      end

      it "reads string" do
        str = "Hello world\r\nFoo\nBar"
        io = PatchSimpleIOMemory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.read_string(11).should eq("Hello world")
        io.gets_to_end.should eq("\r\nFoo\nBar")
      end

      it "gets ascii from socket (#9056)" do
        server = TCPServer.new "localhost", 0
        sock = TCPSocket.new "localhost", server.local_address.port
        begin
          sock.set_encoding("ascii")
          spawn do
            client = server.accept
            message = client.gets
            client << "#{message}\n"
          end
          sock << "K\n"
          sock.gets.should eq("K")
        ensure
          server.close
          sock.close
        end
      end
    end

    describe "encode" do
      it "prints a string" do
        str = "Hello world"
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print str
        slice = io.to_slice
        slice.should eq(str.encode("UTF-16LE"))
      end

      it "prints numbers" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print 0
        io.print 1_u8
        io.print 2_u16
        io.print 3_u32
        io.print 4_u64
        io.print 5_i8
        io.print 6_i16
        io.print 7_i32
        io.print 8_i64
        io.print 9.1_f32
        io.print 10.11_f64
        slice = io.to_slice
        slice.should eq("0123456789.110.11".encode("UTF-16LE"))
      end

      it "prints bool" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print true
        io.print false
        slice = io.to_slice
        slice.should eq("truefalse".encode("UTF-16LE"))
      end

      it "prints char" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print 'a'
        slice = io.to_slice
        slice.should eq("a".encode("UTF-16LE"))
      end

      it "prints symbol" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print :foo
        slice = io.to_slice
        slice.should eq("foo".encode("UTF-16LE"))
      end

      it "prints big int" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.print 123_456.to_big_i
        slice = io.to_slice
        slice.should eq("123456".encode("UTF-16LE"))
      end

      it "puts" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.puts 1
        io.puts
        slice = io.to_slice
        slice.should eq("1\n\n".encode("UTF-16LE"))
      end

      it "printf" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.printf "%s-%d-%.2f", "hi", 123, 45.67
        slice = io.to_slice
        slice.should eq("hi-123-45.67".encode("UTF-16LE"))
      end

      it "raises on invalid byte sequence" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("EUC-JP")
        expect_raises ArgumentError, "Malformed UTF-8 input" do
          io.print "\xff"
        end
      end

      it "skips on invalid byte sequence" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("EUC-JP", invalid: :skip)
        io.print "ñ"
        io.print "foo"
      end

      it "raises when a later write makes an incomplete UTF-8 sequence invalid" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("EUC-JP")
        io.print "好".byte_slice(0, 1)
        io.to_slice.should be_empty
        expect_raises ArgumentError, "Malformed UTF-8 input" do
          io.print "A"
        end
      end

      it "raises when changing encoding finalizes an incomplete UTF-8 sequence" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("EUC-JP")
        io.print "好".byte_slice(0, 1)
        expect_raises ArgumentError, "Malformed UTF-8 input" do
          io.set_encoding("UTF-8")
        end
      end

      it "says invalid encoding" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("FOO")
        expect_raises ArgumentError, "Unknown encoding: \"FOO\"" do
          io.puts "a"
        end
      end
    end

    describe "#encoding" do
      it "returns \"UTF-8\" if the encoding is not manually set" do
        PatchSimpleIOMemory.new.encoding.should eq("UTF-8")
      end

      it "returns the name of the encoding set via #set_encoding" do
        io = PatchSimpleIOMemory.new
        io.set_encoding("UTF-16LE")
        io.encoding.should eq("UTF-16LE")
      end
    end
  end
end

describe "stdlib IO::Buffered encoding compatibility" do
  describe "encoding" do
    describe "decode" do
      it "gets_to_end" do
        str = "Hello world" * 200
        base_io = IO::Memory.new(str.encode("UTF-16LE"))
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("UTF-16LE")
        io.gets_to_end.should eq(str)
      end

      it "gets" do
        str = "Hello world\nFoo\nBar\n" + ("1234567890" * 1000)
        base_io = IO::Memory.new(str.encode("UTF-16LE"))
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("UTF-16LE")
        io.gets.should eq("Hello world")
        io.gets.should eq("Foo")
        io.gets.should eq("Bar")
      end

      it "gets with chomp = false" do
        str = "Hello world\nFoo\nBar\n" + ("1234567890" * 1000)
        base_io = IO::Memory.new(str.encode("UTF-16LE"))
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("UTF-16LE")
        io.gets(chomp: false).should eq("Hello world\n")
        io.gets(chomp: false).should eq("Foo\n")
        io.gets(chomp: false).should eq("Bar\n")
      end

      it "gets big string" do
        str = "Hello\nWorld\n" * 10_000
        base_io = IO::Memory.new(str.encode("UTF-16LE"))
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("UTF-16LE")
        10_000.times do |i|
          io.gets(chomp: false).should eq("Hello\n")
          io.gets(chomp: false).should eq("World\n")
        end
      end

      it "gets big EUC-JP string" do
        str = ("好我是人\n" * 1000).encode("EUC-JP")
        base_io = IO::Memory.new(str)
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("EUC-JP")
        1000.times do
          io.gets(chomp: false).should eq("好我是人\n")
        end
      end

      it "reads char" do
        str = "x\nHello world" + ("1234567890" * 1000)
        base_io = IO::Memory.new(str.encode("UTF-16LE"))
        io = PatchBufferedWrapper.new(base_io)
        io.set_encoding("UTF-16LE")
        io.gets(chomp: false).should eq("x\n")
        str = str[2..-1]
        str.each_char do |char|
          io.read_char.should eq(char)
        end
        io.read_char.should be_nil
      end
    end
  end
end

describe "stdlib IO::Memory decoding encoding compatibility" do
  describe "encoding" do
    describe "decode" do
      it "gets_to_end" do
        str = "Hello world" * 200
        io = IO::Memory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets_to_end.should eq(str)
      end

      it "gets" do
        str = "Hello world\nFoo\nBar\n" + ("1234567890" * 1000)
        io = IO::Memory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(chomp: false).should eq("Hello world\n")
        io.gets(chomp: false).should eq("Foo\n")
        io.gets(chomp: false).should eq("Bar\n")
      end

      it "gets with chomp = false" do
        str = "Hello world\nFoo\nBar\n" + ("1234567890" * 1000)
        io = IO::Memory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets.should eq("Hello world")
        io.gets.should eq("Foo")
        io.gets.should eq("Bar")
      end

      it "reads char" do
        str = "x\nHello world" + ("1234567890" * 1000)
        io = IO::Memory.new(str.encode("UTF-16LE"))
        io.set_encoding("UTF-16LE")
        io.gets(chomp: false).should eq("x\n")
        str = str[2..-1]
        str.each_char do |char|
          io.read_char.should eq(char)
        end
        io.read_char.should be_nil
      end
    end
  end
end

describe "stdlib IO::Memory conversion encoding compatibility" do
  describe "encoding" do
    it "returns String" do
      io = IO::Memory.new
      io.set_encoding "UTF-16LE"
      io << "abc"
      io.to_s.should eq "abc"
      io.to_slice.should eq Bytes[0x61, 0x00, 0x62, 0x00, 0x63, 0x00]
    end

    it "writes to IO" do
      io1 = IO::Memory.new
      io1.set_encoding "UTF-32LE"

      io2 = IO::Memory.new
      io2.set_encoding "UTF-16LE"

      io1.write_string "abc😂".to_slice
      io1.to_s io2
      byte_slice = io2.to_slice
      utf16_slice = byte_slice.unsafe_slice_of(UInt16)

      String.from_utf16(utf16_slice).should eq "abc😂"
      byte_slice.should eq Bytes[0x61, 0x00, 0x62, 0x00, 0x63, 0x00, 0x3D, 0xD8, 0x02, 0xDE]
      utf16_slice.should eq Slice[0x0061, 0x0062, 0x0063, 0xD83D, 0xDE02]
    end
  end
end
