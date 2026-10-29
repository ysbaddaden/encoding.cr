require "./spec_helper"

describe "Pinned WPT conformance" do
  it "matches imported decoder and encoder assertions" do
    fixture("wpt.json").as_a.each do |row|
      name = "#{row["source"]}: #{row["test"]}"
      encoding = row["encoding"].as_s
      if row["direction"]?.try(&.as_s) == "encode"
        input = row["input"].as_s
        if row["error"].as_bool
          expect_raises(Encoding::UndefinedConversionError) { Encoding.encode(input, encoding, errors: :strict) }
        else
          actual = Encoding.encode(input, encoding, errors: :strict)
          fail "#{name}: #{actual.inspect}" unless actual == bytes(row["bytes"])
          (0..input.bytesize).each do |split|
            encoder = Encoding::Encoder.new(encoding, errors: :strict)
            stream = IO::Memory.new
            stream.write(encoder.feed(input.to_slice[0, split]))
            stream.write(encoder.feed(Bytes.empty))
            stream.write(encoder.feed(input.to_slice[split..]))
            stream.write(encoder.finish)
            fail "#{name}: split #{split}" unless stream.to_slice == actual
          end
        end
      else
        decoder = Encoding::Decoder.new(encoding,
          errors: row["strict"].as_bool ? Encoding::ErrorMode::Strict : Encoding::ErrorMode::Replace,
          bom: row["bom"].as_s == "strip" ? Encoding::BOMPolicy::Strip : Encoding::BOMPolicy::Preserve)
        decoded = ""
        operation = -> {
          row["calls"].as_a.each do |call|
            decoded = decoder.feed(bytes(call["bytes"]))
            decoded += decoder.finish unless call["stream"].as_bool
          end
        }
        if row["error"].as_bool
          expect_raises(Encoding::InvalidByteSequenceError) { operation.call }
        else
          operation.call
          expected = row["expected"]
          if unit = row["unit"].as_i?
            units = [] of Int32
            decoded.each_codepoint do |cp|
              if cp < 0x10000
                units << cp
              else
                units << 0xd800 + ((cp - 0x10000) >> 10)
                units << 0xdc00 + ((cp - 0x10000) & 1023)
              end
            end
            fail name unless units[unit] == expected.as_i
          elsif row["not"]?.try(&.as_bool)
            fail name if decoded == expected.as_s
          else
            fail "#{name}: got #{decoded.inspect}, expected #{expected.as_s.inspect}" unless decoded == expected.as_s
          end
        end
      end
    end
  end

  fixture("wpt-reference.json").as_a.each do |group|
    encoding = group["encoding"].as_s
    it "matches exhaustive WPT reference decoding for #{encoding}" do
      decoder = Encoding::Decoder.new(encoding, bom: :preserve)
      group["rows"].as_a.each do |row|
        input = bytes(row[0])
        expected = row[1].as_s
        actual = decoder.feed(input) + decoder.finish
        fail "#{encoding} #{input.inspect}: #{actual.inspect} != #{expected.inspect}" unless actual == expected
        decoder.reset
        # Repeat with every byte in a separate chunk, including empty chunks.
        actual = String.build do |output|
          input.each do |byte|
            output << decoder.feed(Bytes[byte])
            output << decoder.feed(Bytes.empty)
          end
          output << decoder.finish
        end
        fail "#{encoding} chunked #{input.inspect}: #{actual.inspect} != #{expected.inspect}" unless actual == expected
        decoder.reset
      end
    end
  end

  fixture("wpt-encoders.json").as_a.each do |group|
    encoding = group["encoding"].as_s
    it "matches all mapped WPT reference encoder code points for #{encoding}" do
      encoder = Encoding::Encoder.new(encoding, errors: :strict)
      group["rows"].as_a.each do |row|
        cp = row[0].as_i
        input = cp.chr.to_s
        if row[1].raw.nil?
          expect_raises(Encoding::UndefinedConversionError) { encoder.feed(input) }
        else
          output = IO::Memory.new
          output.write(encoder.feed(input))
          output.write(encoder.finish)
          expected = bytes(row[1])
          fail "#{encoding} U+#{cp.to_s(16)}: #{output.to_slice.inspect} != #{expected.inspect}" unless output.to_slice == expected
        end
        encoder.reset
      end
    end
  end

  fixture("wpt-single-byte.json").as_h.each do |encoding, index|
    it "matches all WPT bytes and their encodings for #{encoding}" do
      256.times do |byte|
        cp = byte < 128 ? byte : index[byte - 128].as_i?
        input = Bytes[byte.to_u8]
        if cp
          Encoding.decode(input, encoding, errors: :strict).should eq(cp.chr.to_s)
          Encoding.encode(cp.chr.to_s, encoding, errors: :strict).should eq(input)
        else
          Encoding.decode(input, encoding).should eq("�")
          expect_raises(Encoding::InvalidByteSequenceError) { Encoding.decode(input, encoding, errors: :strict) }
        end
      end
    end
  end

  it "resolves every WPT label with ASCII case and whitespace normalization" do
    fixture("wpt-labels.json").as_a.each do |group|
      group["encodings"].as_a.each do |encoding|
        encoding["labels"].as_a.each do |label|
          Encoding.find(label.as_s).name.should eq(encoding["name"].as_s)
          Encoding.find("\t\n\f\r #{label.as_s.upcase(:ascii)} \r\n").name.should eq(encoding["name"].as_s)
        end
      end
    end
  end
end
