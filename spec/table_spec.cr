require "./spec_helper"

module Encoding
  describe "literal decoding tables" do
    it "stores unsigned BMP values and preserves undefined entries and bounds" do
      table = Table.new(Slice(UInt16).literal(0x7fff, 0x8000, 0xd7ff, 0xe000, 0xfffe, 0xffff))
      {0x7fff, 0x8000, 0xd7ff, 0xe000, 0xfffe, -1}.each_with_index do |cp, pointer|
        table.codepoint_at(pointer).should eq(cp)
      end
      table.codepoint_at(-1).should eq(-1)
      table.codepoint_at(6).should eq(-1)
      table.size.should eq(6)
    end

    it "stores supplementary Big5 mappings directly" do
      table = Table.new(Data::BIG5)
      table.codepoint_at(947).should eq(0x27267)
      table.codepoint_at(19780).should eq(0x2910d)
    end

    it "preserves undefined entries and bounds in Int32 tables" do
      table = Table.new(Slice(Int32).literal(0x20021, -1, 0xffff))
      table.codepoint_at(0).should eq(0x20021)
      table.codepoint_at(1).should eq(-1)
      table.codepoint_at(-1).should eq(-1)
      table.codepoint_at(2).should eq(0xffff)
      table.codepoint_at(3).should eq(-1)
      table.size.should eq(3)
    end
  end

  describe "lazy reverse tables" do
    it "uses byte pointers for single-byte encodings and UInt16 for multibyte encodings" do
      Table.reverse("windows-1252").should be_a(Table::Reverse(UInt8))
      Table.reverse("big5").should be_a(Table::Reverse(UInt16))
    end

    {% for type in [UInt8, UInt16] %}
      it "preserves pointer boundaries and unmapped entries in {{type}} tables" do
        table = Table::Reverse({{type}}).new(3)
        table[0]?.should be_nil
        table[-1]?.should be_nil
        table[3]?.should be_nil
        table[Int32::MAX]?.should be_nil

        table[0] = 0
        table[1] = {{type}}::MAX.to_i32 - 1
        table[0]?.should eq(0)
        table[1]?.should eq({{type}}::MAX.to_i32 - 1)
        table[2]?.should be_nil

        expect_raises(Exception, "Reverse pointer exceeds {{type}}") { table[2] = -1 }
        expect_raises(Exception, "Reverse pointer exceeds {{type}}") { table[2] = {{type}}::MAX.to_i32 }
        expect_raises(Exception, "Reverse pointer exceeds {{type}}") { table[2] = {{type}}::MAX.to_i32 + 1 }
        table[2]?.should be_nil
      end
    {% end %}

    it "matches the reference mapping rules, including holes and page boundaries" do
      (Data::LABELS.values.map { |name| Table.index_name(name) }.select { |name| Table.for?(name) } + ["shift_jis"]).uniq.each do |name|
        table = Table.reverse(name)
        Table.reverse(name).data.to_unsafe.should eq(table.data.to_unsafe)
        index = name == "shift_jis" ? "jis0208" : name
        data = Table.for(index)
        expected = {} of Int32 => Int32
        data.size.times do |pointer|
          next if name == "shift_jis" && (8272..8835).includes?(pointer)
          next if name == "big5" && pointer < 5024
          cp = data.codepoint_at(pointer)
          next if cp < 0
          if name == "big5" && {0x2550, 0x255e, 0x2561, 0x256a, 0x5341, 0x5345}.includes?(cp)
            expected[cp] = pointer
          else
            expected[cp] ||= pointer
          end
        end
        expected.each_key do |cp|
          {-1, 0, 1}.each do |delta|
            value = cp + delta
            table[value]?.should eq(expected[value]?)
          end
        end
        {-1, 0, 127, 128, 255, 256, 0xffff, 0x10000, 0x10ffff, 0x110000, Int32::MAX}.each do |cp|
          table[cp]?.should eq(expected[cp]?)
        end
      end
    end
  end
end
