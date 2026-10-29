require "./spec_helper"

module Encoding
  describe "gb18030 range lookup" do
    it "matches a linear reference around every range boundary" do
      reader = Reader::Chinese.new
      writer = Writer::GB18030.new

      Data::GB18030_RANGES.each do |pointer, cp|
        {-1, 0, 1}.each do |delta|
          value = pointer + delta
          pair = Data::GB18030_RANGES[0]

          Data::GB18030_RANGES.each do |entry|
            break if entry[0] > value
            pair = entry
          end

          expected = if (39420...189000).includes?(value) || value > 1237575
                       -1
                     elsif value == 7457
                       0xe7c7
                     else
                       pair[1] + value - pair[0]
                     end
          reader.range_codepoint(value).should eq(expected)

          value = cp + delta
          pair = Data::GB18030_RANGES[0]
          Data::GB18030_RANGES.each do |entry|
            break if entry[1] > value
            pair = entry
          end
          expected = value == 0xe7c7 ? 7457 : pair[0] + value - pair[1]
          writer.range_pointer(value).should eq(expected)
        end
      end
    end

    it "preserves the excluded pointer interval, maximum, and special mapping" do
      reader = Reader::Chinese.new
      reader.range_codepoint(39419).should eq(0xffff)
      reader.range_codepoint(39420).should eq(-1)
      reader.range_codepoint(188999).should eq(-1)
      reader.range_codepoint(189000).should eq(0x10000)
      reader.range_codepoint(1237575).should eq(0x10ffff)
      reader.range_codepoint(1237576).should eq(-1)
      reader.range_codepoint(7457).should eq(0xe7c7)

      writer = Writer::GB18030.new
      writer.range_pointer(0xe7c7).should eq(7457)
    end
  end
end
