# Run with --release. Uses the same payloads and cases as encoding.cr.
require "benchmark"
require "option_parser"
require "../src/encoding"
require "c/iconv"

module IconvBench
  class Options
    property encodings = ["UTF-8", "windows-1252", "Shift_JIS", "GBK", "UTF-16LE"]
    property sizes = [16, 256, 4096, 65536]
    property direction = "both"
    property warmup = 0.1
    property calculation = 0.5

    def initialize(args : Array(String))
      OptionParser.parse(args) do |p|
        p.banner = "Usage: crystal run --release bench/libiconv.cr -- [options]"
        p.on("--encodings LIST", "Comma-separated WHATWG labels") { |v| @encodings = v.split(',').map { |n| Encoding.find(n).name }.uniq }
        p.on("--sizes LIST", "UTF-8 payload byte lengths") { |v| @sizes = v.split(',').map(&.to_i) }
        p.on("--direction NAME", "encode, decode, or both") { |v| @direction = v }
        p.on("--warmup SECONDS", "") { |v| @warmup = v.to_f }
        p.on("--time SECONDS", "") { |v| @calculation = v.to_f }
        p.on("-h", "--help") { puts p; exit }
      end
    end
  end

  class Case
    getter encoding : String
    getter text : String
    getter encoded : Bytes

    def initialize(@encoding : String, size : Int32)
      corpus = case @encoding
               when "UTF-8", "UTF-16LE"
                 "Crystal 日本語 café 😀 0123.\n"
               when "Shift_JIS"
                 "Crystal 日本語 0123.\n"
               when "GBK"
                 "Crystal 中文 0123.\n"
               when "windows-1252"
                 "Crystal café 0123.\n"
               else
                 "Crystal 0123.\n"
               end
      @text = String.build do |s|
        while s.bytesize < size
          s << corpus
        end
      end
      @encoded = Encoding.encode(@text, @encoding, errors: :strict)
      raise "Round trip failed: #{@encoding}" unless Encoding.decode(@encoded, @encoding, errors: :strict) == @text
    end

    private def convert(bytes : Bytes, from : String, to : String) : Bytes
      cd = LibC.iconv_open(to, from)
      raise "libiconv does not support #{from} -> #{to}" if cd.null?
      output = Bytes.new(bytes.size * 8 + 32)
      input_left = LibC::SizeT.new!(bytes.size)
      output_left = LibC::SizeT.new!(output.size)
      input = bytes.to_unsafe.as(LibC::Char*)
      out = output.to_unsafe.as(LibC::Char*)
      input_ptr = pointerof(input)
      output_ptr = pointerof(out)
      result = LibC.iconv(cd, input_ptr, pointerof(input_left), output_ptr, pointerof(output_left))
      LibC.iconv_close(cd)
      raise "libiconv conversion failed" if result == LibC::SizeT::MAX || input_left != 0
      output[0, output.size - output_left]
    end

    def run(direction : String) : UInt64
      bytes = direction == "encode" ? @text.to_slice : @encoded
      from, to = direction == "encode" ? {"UTF-8", @encoding} : {@encoding, "UTF-8"}
      result = convert(bytes, from, to)
      result.size.to_u64 ^ (result[0].to_u64 << 8) ^ (result[-1].to_u64 << 16)
    end

    def run_crystal(direction : String) : UInt64
      result = if direction == "encode"
                 Encoding.encode(@text, @encoding)
               else
                 Encoding.decode(@encoded, @encoding).to_slice
               end
      result.size.to_u64 ^ (result[0].to_u64 << 8) ^ (result[-1].to_u64 << 16)
    end

    def label(direction : String) : String
      "#{direction}/#{@encoding}/utf8=#{@text.bytesize}"
    end
  end

  options = Options.new(ARGV)
  checksum = 0_u64
  puts "Encoding #{Encoding::VERSION} vs Iconv; Crystal #{Crystal::VERSION}; release build"
  options.encodings.each do |encoding|
    {"encode", "decode"}.each do |direction|
      options.sizes.each do |size|
        item = Case.new(encoding, size)
        next if options.direction != "both" && options.direction != direction

        Benchmark.ips(warmup: options.warmup.seconds, calculation: options.calculation.seconds) do |job|
          job.report("Crystal/#{item.label(direction)}") { checksum &+= item.run_crystal(direction) }
          job.report("Iconv/#{item.label(direction)}") { checksum &+= item.run(direction) }
        end
        puts
      end
    end
  end
  puts "Result sink: #{checksum}"
end
