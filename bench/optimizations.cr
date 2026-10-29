# Targeted workloads for changes not covered by the general encoding benchmark.
# Build with: crystal build --release bench/optimizations.cr -o /tmp/encoding-targeted
require "benchmark"
require "../src/encoding"

{% unless flag?(:release) %}
  raise "Build with --release"
{% end %}

# Also provides a small executable for external process-startup measurements.
exit if ARGV.first? == "startup"

case ARGV.first?
when "ranges"
  text = "😀𐀀\u0080\uFFFF" * 512
  encoded = Encoding.encode(text, "gb18030", errors: :strict)
  raise "Range corpus does not round trip" unless Encoding.decode(encoded, "gb18030", errors: :strict) == text
  checksum = 0_u64
  Benchmark.ips(warmup: 0.2.seconds, calculation: 1.second) do |job|
    job.report("gb18030/ranges/encode") { checksum &+= Encoding.encode(text, "gb18030", errors: :strict).size.to_u64 }
    job.report("gb18030/ranges/decode") { checksum &+= Encoding.decode(encoded, "gb18030", errors: :strict).bytesize.to_u64 }
  end
  puts "Result sink: #{checksum}"
when "replacements"
  text = "😀" * 1024
  malformed = Bytes.new(4096, 0xff_u8)
  japanese = "日😀" * 512
  raise "Replacement validation failed" unless Encoding.decode(
                                                 Encoding.encode(japanese, "iso-2022-jp", replacement: "代?"), "iso-2022-jp") == "日代?" * 512
  checksum = 0_u64
  Benchmark.ips(warmup: 0.2.seconds, calculation: 1.second) do |job|
    job.report("replace/windows-1252") { checksum &+= Encoding.encode(text, "windows-1252", replacement: "[?]").size.to_u64 }
    job.report("replace/UTF-16LE/malformed") { checksum &+= Encoding.encode(malformed, "UTF-16LE", replacement: "[?]").size.to_u64 }
    job.report("replace/ISO-2022-JP") { checksum &+= Encoding.encode(japanese, "iso-2022-jp", replacement: "代?").size.to_u64 }
  end
  puts "Result sink: #{checksum}"
when "setup"
  replacement = "[?]" * 32
  checksum = 0_u64
  Benchmark.ips(warmup: 0.2.seconds, calculation: 1.second) do |job|
    job.report("setup/default") { checksum &+= Encoding::Encoder.new("windows-1252").replacement.bytesize.to_u64 }
    job.report("setup/96-codepoints") { checksum &+= Encoding::Encoder.new("windows-1252", replacement: replacement).replacement.bytesize.to_u64 }
    job.report("setup/ISO-2022-JP") { checksum &+= Encoding::Encoder.new("iso-2022-jp", replacement: "代?" * 32).replacement.bytesize.to_u64 }
  end
  puts "Result sink: #{checksum}"
when "bom"
  input = Bytes[0xef, 0xbb, 0xbf, 0x41]
  chunks = Array(Bytes).new(input.size) { |i| input[i, 1] }
  ascii = "A".to_slice
  checksum = 0_u64
  Benchmark.ips(warmup: 0.2.seconds, calculation: 1.second) do |job|
    job.report("bom/whole") { checksum &+= Encoding.decode(input).bytesize.to_u64 }
    job.report("bom/split") do
      decoder = Encoding::Decoder.new
      chunks.each { |chunk| checksum &+= decoder.feed(chunk).bytesize.to_u64 }
      checksum &+= decoder.finish.bytesize.to_u64
    end
    job.report("bom/ascii") { checksum &+= Encoding.decode(ascii).bytesize.to_u64 }
  end
  puts "Result sink: #{checksum}"
when "utf8"
  malformed = Bytes.new(4096, 0xff_u8)
  truncated = (("😀A" * 800) + "\xf0\x9f").to_slice
  checksum = 0_u64
  Benchmark.ips(warmup: 0.2.seconds, calculation: 1.second) do |job|
    job.report("utf8/malformed/encode") { checksum &+= Encoding.encode(malformed).size.to_u64 }
    job.report("utf8/malformed/decode") { checksum &+= Encoding.decode(malformed).bytesize.to_u64 }
    job.report("utf8/truncated/encode") { checksum &+= Encoding.encode(truncated).size.to_u64 }
    job.report("utf8/truncated/decode") { checksum &+= Encoding.decode(truncated).bytesize.to_u64 }
  end
  puts "Result sink: #{checksum}"
else
  raise ArgumentError.new("Expected ranges, replacements, setup, bom, utf8, or startup")
end
