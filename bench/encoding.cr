# Run with --release. All inputs are prepared and validated before timing.
require "benchmark"
require "option_parser"
require "../src/encoding"

module EncodingBench
  ASCII = "The quick brown fox jumps over the lazy dog. 0123456789\n"

  class Options
    property encodings = "all"
    property sizes = [16, 256, 4096, 65536]
    property direction = "both"
    property profile = "both"
    property warmup = 0.1
    property calculation = 0.5
    property chunk_size : Int32? = nil

    def initialize(args : Array(String))
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: crystal run --release bench/encoding.cr -- [options]"
        parser.on("--encodings LIST", "Comma-separated WHATWG labels, or all (default)") { |value| @encodings = value }
        parser.on("--sizes LIST", "UTF-8 payload byte lengths (default: 0,16,256,4096,65536)") do |value|
          @sizes = value.split(',').map do |size|
            parsed = size.to_i?
            raise ArgumentError.new("Sizes must be nonnegative integers") unless parsed && parsed >= 0
            parsed
          end.uniq
        end
        parser.on("--direction NAME", "encode, decode, or both (default)") do |value|
          raise ArgumentError.new("Direction must be encode, decode, or both") unless {"encode", "decode", "both"}.includes?(value)
          @direction = value
        end
        parser.on("--profile NAME", "ascii, mixed, or both (default)") do |value|
          raise ArgumentError.new("Profile must be ascii, mixed, or both") unless {"ascii", "mixed", "both"}.includes?(value)
          @profile = value
        end
        parser.on("--warmup SECONDS", "Warmup per case (default: 0.1)") { |value| @warmup = positive_seconds(value) }
        parser.on("--time SECONDS", "Measurement time per case (default: 0.5)") { |value| @calculation = positive_seconds(value) }
        parser.on("--chunk-size BYTES", "Benchmark incremental conversion with this chunk size") do |value|
          parsed = value.to_i?
          raise ArgumentError.new("Chunk size must be a positive integer") unless parsed && parsed > 0
          @chunk_size = parsed
        end
        parser.on("-h", "--help", "Show usage") { puts parser; exit }
        parser.unknown_args { |unknown| raise ArgumentError.new("Unexpected arguments: #{unknown.join(' ')}") unless unknown.empty? }
      end
    end

    private def positive_seconds(value : String) : Float64
      parsed = value.to_f?
      raise ArgumentError.new("Timing durations must be positive finite numbers") unless parsed && parsed.finite? && parsed > 0
      parsed
    end

    def charset_names : Array(String)
      names = if @encodings == "all"
                Encoding.encodings.select(&.can_encode?).map(&.name).sort
              else
                @encodings.split(',').map { |name| Encoding.find(name).name }.uniq
              end
      names.each do |name|
        raise ArgumentError.new("#{name} has no encoder") unless Encoding.find(name).can_encode?
      end
      names
    end
  end

  # Fixed corpora keep the benchmark inputs stable across mapping regeneration.
  def self.corpus(encoding : String) : String
    native = case encoding
             when "UTF-8", "UTF-16LE", "UTF-16BE"
               "日本語 Ελληνικά العربية Русский café 😀"
             when "IBM866", "ISO-8859-5", "KOI8-R", "KOI8-U", "windows-1251", "x-mac-cyrillic"
               "Привет мир"
             when "ISO-8859-6", "windows-1256"
               "مرحبا بالعالم"
             when "ISO-8859-7", "windows-1253"
               "Καλημέρα κόσμε"
             when "ISO-8859-8", "ISO-8859-8-I", "windows-1255"
               "שלום עולם"
             when "windows-874"
               "สวัสดีโลก"
             when "GBK", "Big5"
               "中文世界你好"
             when "gb18030"
               "中文世界你好😀"
             when "EUC-JP", "ISO-2022-JP", "Shift_JIS"
               "日本語かなカナ漢字"
             when "EUC-KR"
               "안녕하세요 세계 한국어"
             when "x-user-defined"
               "\uF780\uF7A0\uF7C0\uF7FF"
             else
               "éÉäÄöÖüÜ"
             end
    "Crystal #{native} 0123.\n"
  end

  # Exact UTF-8 byte lengths without splitting characters. Pad the tail with
  # ASCII where a multibyte character would exceed the requested length.
  def self.payload(corpus : String, size : Int32) : String
    String.build do |output|
      output << corpus * (size // corpus.bytesize)
      remaining = size % corpus.bytesize
      corpus.each_char do |char|
        break if char.bytesize > remaining
        output << char
        remaining -= char.bytesize
      end
      remaining.times { output << 'a' }
    end
  end

  class Workload
    getter encoding : String
    getter profile : String
    getter text : String
    getter encoded : Bytes

    def initialize(@encoding : String, @profile : String, size : Int32, @chunk_size : Int32?)
      @text = EncodingBench.payload(@profile == "ascii" ? ASCII : EncodingBench.corpus(@encoding), size)
      # Preparation and strict validation are deliberately outside measurement.
      @encoded = Encoding.encode(@text, @encoding, errors: :strict)
      unless Encoding.decode(@encoded, @encoding, errors: :strict) == @text
        raise "Benchmark corpus does not round trip: #{@encoding}/#{@profile}"
      end
      validate_chunks if @chunk_size
    end

    private def consume(bytes : Bytes) : UInt64
      return 0_u64 if bytes.empty?
      bytes.size.to_u64 ^ (bytes[0].to_u64 << 8) ^ (bytes[-1].to_u64 << 16)
    end

    def encode : UInt64
      if chunk_size = @chunk_size
        encoder = Encoding::Encoder.new(@encoding)
        checksum = 0_u64
        each_chunk(@text.to_slice, chunk_size) { |chunk| checksum &+= consume(encoder.feed(chunk)) }
        checksum &+ consume(encoder.finish)
      else
        consume(Encoding.encode(@text, @encoding))
      end
    end

    def decode : UInt64
      if chunk_size = @chunk_size
        decoder = Encoding::Decoder.new(@encoding)
        checksum = 0_u64
        each_chunk(@encoded, chunk_size) { |chunk| checksum &+= consume(decoder.feed(chunk).to_slice) }
        checksum &+ consume(decoder.finish.to_slice)
      else
        consume(Encoding.decode(@encoded, @encoding).to_slice)
      end
    end

    private def each_chunk(bytes : Bytes, size : Int32, &block : Bytes ->) : Nil
      position = 0
      while position < bytes.size
        count = Math.min(size, bytes.size - position)
        yield bytes[position, count]
        position += count
      end
    end

    private def validate_chunks : Nil
      chunk_size = @chunk_size.not_nil!
      encoder = Encoding::Encoder.new(@encoding, errors: :strict)
      bytes = IO::Memory.new
      each_chunk(@text.to_slice, chunk_size) { |chunk| bytes.write(encoder.feed(chunk)) }
      bytes.write(encoder.finish)
      raise "Incremental encoding differs for #{@encoding}" unless bytes.to_slice == @encoded
      decoder = Encoding::Decoder.new(@encoding, errors: :strict)
      text = String.build do |output|
        each_chunk(@encoded, chunk_size) { |chunk| output << decoder.feed(chunk) }
        output << decoder.finish
      end
      raise "Incremental decoding differs for #{@encoding}" unless text == @text
    end

    def label(direction : String) : String
      input_size = direction == "encode" ? @text.bytesize : @encoded.size
      "#{direction}/#{@encoding}/#{@profile}/utf8=#{@text.bytesize}/in=#{input_size}"
    end
  end

  def self.run(args : Array(String)) : Nil
    options = Options.new(args)
    {% unless flag?(:release) %}
      raise ArgumentError.new("Build with --release for meaningful benchmark results")
    {% end %}
    profiles = options.profile == "both" ? ["ascii", "mixed"] : [options.profile]
    workloads = [] of Workload
    options.charset_names.each do |encoding|
      options.sizes.each do |size|
        # The empty input is identical for both profiles; measure it once.
        selected = size == 0 ? profiles.first(1) : profiles
        selected.each { |profile| workloads << Workload.new(encoding, profile, size, options.chunk_size) }
      end
    end
    directions = options.direction == "both" ? ["encode", "decode"] : [options.direction]
    cases = workloads.size * directions.size
    puts "Encoding #{Encoding::VERSION}; Crystal #{Crystal::VERSION}; release build"
    puts "Mode: #{options.chunk_size ? "incremental (#{options.chunk_size}-byte chunks)" : "one-shot"}; default error/BOM policies"
    puts "#{cases} cases; #{options.warmup}s warmup + #{options.calculation}s measurement per case"
    puts "utf8=payload byte length; in=actual input byte length; B/op=allocated bytes per operation"
    puts "Compare matching rows across revisions; within-run 'fastest' ratios compare different workloads."
    puts
    checksum = 0_u64
    GC.collect
    Benchmark.ips(warmup: options.warmup.seconds, calculation: options.calculation.seconds) do |job|
      workloads.each do |workload|
        if directions.includes?("encode")
          job.report(workload.label("encode")) { checksum &+= workload.encode }
        end
        if directions.includes?("decode")
          job.report(workload.label("decode")) { checksum &+= workload.decode }
        end
      end
    end
    # Keep results observable to prevent dead-code elimination. This value
    # depends on the number of timed iterations and is not a comparison metric.
    puts "\nResult sink: #{checksum}"
  end
end

begin
  EncodingBench.run(ARGV)
rescue ex : ArgumentError | Encoding::Error
  STDERR.puts ex.message
  exit 1
end
