require "./ascii"

module Encoding
  private abstract struct Writer
    def self.for(name : String) : Writer
      if table = Table.single_byte?(name)
        return SingleByte.new(Table.reverse(name, table, UInt8))
      end

      case name
      when "UTF-8"          then UTF8.new
      when "UTF-32LE"       then UTF32LE.new
      when "UTF-32BE"       then UTF32BE.new
      when "UTF-16LE"       then UTF16LE.new
      when "UTF-16BE"       then UTF16BE.new
      when "GBK"            then GBK.new
      when "gb18030"        then GB18030.new
      when "Big5"           then Big5.new
      when "Shift_JIS"      then ShiftJIS.new
      when "EUC-JP"         then EUCJP.new
      when "EUC-KR"         then EUCKR.new
      when "ISO-2022-JP"    then ISO2022JP.new
      when "x-user-defined" then UserDefined.new
      else
        raise UnsupportedEncodingError.new("No encoder for #{name}")
      end
    end

    # Legacy writers may receive unvalidated input here and must accept only
    # destination-safe ASCII. The UTF-8 writer receives validated spans only.
    def span_end(input : Bytes, position : Int32) : Int32
      ASCII.end_of_run(input, position)
    end

    def write_span(bytes : Bytes, output : IO) : Nil
      output.write(bytes)
    end

    private def put(output : IO, *bytes : Int32) : Bool
      bytes.each { |byte| output.write_byte(byte.to_u8) }
      true
    end

    def finish(output : IO) : Nil
    end

    abstract def write(cp : Int32, output : IO) : Bool
  end

  struct Writer::UTF8 < Writer
    def span_end(input : Bytes, position : Int32) : Int32
      input.size
    end

    def write(cp : Int32, output : IO) : Bool
      output << cp.chr
      true
    end
  end

  abstract struct Writer::UTF16 < Writer
    private abstract def unit(value : Int32, output : IO) : Nil

    def write(cp : Int32, output : IO) : Bool
      if cp >= 0x10000
        unit(0xd800 + ((cp - 0x10000) >> 10), output)
        unit(0xdc00 + ((cp - 0x10000) & 1023), output)
      else
        unit(cp, output)
      end
      true
    end

    # Batch ASCII units using small local buffer to avoid per-byte IO calls.
    private def write_span_impl(bytes, output, &) : Nil
      buffer = uninitialized UInt8[256]
      pointer = buffer.to_unsafe

      bytes.each do |byte|
        yield pointer, byte
        pointer += 2

        if pointer == buffer.to_unsafe + buffer.size
          output.write(buffer.to_slice)
          pointer = buffer.to_unsafe
        end
      end

      position = pointer - buffer.to_unsafe
      output.write(buffer.to_slice[0, position]) if position > 0
    end
  end

  struct Writer::UTF16LE < Writer::UTF16
    def write_span(bytes : Bytes, output : IO) : Nil
      write_span_impl(bytes, output) do |buffer, byte|
        buffer[0] = byte
        buffer[1] = 0_u8
      end
    end

    private def unit(value : Int32, output : IO) : Nil
      put(output, value & 255, value >> 8)
    end
  end

  struct Writer::UTF16BE < Writer::UTF16
    def write_span(bytes : Bytes, output : IO) : Nil
      write_span_impl(bytes, output) do |buffer, byte|
        buffer[0] = 0_u8
        buffer[1] = byte
      end
    end

    private def unit(value : Int32, output : IO) : Nil
      put(output, value >> 8, value & 255)
    end
  end

  struct Writer::UTF32LE < Writer
    def span_end(input : Bytes, position : Int32) : Int32
      position
    end

    def write(cp : Int32, output : IO) : Bool
      put(output, cp & 255, (cp >> 8) & 255, (cp >> 16) & 255, cp >> 24)
    end
  end

  struct Writer::UTF32BE < Writer
    def span_end(input : Bytes, position : Int32) : Int32
      position
    end

    def write(cp : Int32, output : IO) : Bool
      put(output, cp >> 24, (cp >> 16) & 255, (cp >> 8) & 255, cp & 255)
    end
  end

  struct Writer::SingleByte < Writer
    @table : Table::Reverse(UInt8)

    def initialize(@table : Table::Reverse(UInt8))
    end

    def write(cp : Int32, output : IO) : Bool
      if cp < 128
        put(output, cp)
      elsif pointer = @table[cp]?
        put(output, pointer + 128)
      else
        false
      end
    end
  end

  struct Writer::UserDefined < Writer
    def write(cp : Int32, output : IO) : Bool
      if cp < 128
        put(output, cp)
      elsif (0xf780..0xf7ff).includes?(cp)
        put(output, cp - 0xf700)
      else
        false
      end
    end
  end

  abstract struct Writer::Chinese < Writer
    @table : Table::Reverse(UInt16) = Table.reverse("gb18030", Table.new(Data::GB18030))

    GB_EXCEPTIONS = {
      0xe78d => {0xa6, 0xd9}, 0xe78e => {0xa6, 0xda}, 0xe78f => {0xa6, 0xdb},
      0xe790 => {0xa6, 0xdc}, 0xe791 => {0xa6, 0xdd}, 0xe792 => {0xa6, 0xde},
      0xe793 => {0xa6, 0xdf}, 0xe794 => {0xa6, 0xec}, 0xe795 => {0xa6, 0xed},
      0xe796 => {0xa6, 0xf3}, 0xe81e => {0xfe, 0x59}, 0xe826 => {0xfe, 0x61},
      0xe82b => {0xfe, 0x66}, 0xe82c => {0xfe, 0x67}, 0xe832 => {0xfe, 0x6d},
      0xe843 => {0xfe, 0x7e}, 0xe854 => {0xfe, 0x90}, 0xe864 => {0xfe, 0xa0},
    }

    def write(cp : Int32, output : IO) : Bool
      return put(output, cp) if cp < 128
      return false if cp == 0xe5e5
      return put(output, 0x80) if gbk? && cp == 0x20ac

      if pair = GB_EXCEPTIONS[cp]?
        return put(output, pair[0], pair[1])
      end

      if pointer = @table[cp]?
        trailing = pointer % 190
        return put(output, pointer // 190 + 0x81, trailing + (trailing < 63 ? 0x40 : 0x41))
      end
      return false if gbk?

      pointer = range_pointer(cp)
      put(output, pointer // 12600 + 0x81, (pointer % 12600) // 1260 + 0x30, (pointer % 1260) // 10 + 0x81, pointer % 10 + 0x30)
    end

    private def gbk? : Bool
      false
    end

    protected def range_pointer(cp : Int32) : Int32
      return 7457 if cp == 0xe7c7

      lower = 0
      upper = Data::GB18030_RANGES.size

      while lower < upper
        middle = lower + (upper - lower) // 2
        if Data::GB18030_RANGES[middle][1] <= cp
          lower = middle + 1
        else
          upper = middle
        end
      end

      pair = Data::GB18030_RANGES[Math.max(0, lower - 1)]
      pair[0] + cp - pair[1]
    end
  end

  struct Writer::GB18030 < Writer::Chinese
  end

  struct Writer::GBK < Writer::Chinese
    private def gbk? : Bool
      true
    end
  end

  struct Writer::Big5 < Writer
    @table : Table::Reverse(UInt16) = Table.reverse("big5", Table.new(Data::BIG5))

    def write(cp : Int32, output : IO) : Bool
      return put(output, cp) if cp < 128

      if pointer = @table[cp]?
        trailing = pointer % 157
        return put(output, pointer // 157 + 0x81, trailing + (trailing < 63 ? 0x40 : 0x62))
      end

      false
    end
  end

  struct Writer::ShiftJIS < Writer
    @table : Table::Reverse(UInt16) = Table.reverse("shift_jis", Table.new(Data::JIS0208))

    def write(cp : Int32, output : IO) : Bool
      return put(output, cp) if cp < 128
      return put(output, 0x80) if cp == 0x80
      return put(output, 0x5c) if cp == 0xa5
      return put(output, 0x7e) if cp == 0x203e

      if (0xff61..0xff9f).includes?(cp)
        return put(output, cp - 0xff61 + 0xa1)
      end

      cp = 0xff0d if cp == 0x2212
      if pointer = @table[cp]?
        leading = pointer // 188
        trailing = pointer % 188
        return put(output, leading + (leading < 31 ? 0x81 : 0xc1), trailing + (trailing < 63 ? 0x40 : 0x41))
      end

      false
    end
  end

  struct Writer::EUCJP < Writer
    @table : Table::Reverse(UInt16) = Table.reverse("jis0208", Table.new(Data::JIS0208))

    def write(cp : Int32, output : IO) : Bool
      return put(output, cp) if cp < 128
      return put(output, 0x5c) if cp == 0xa5
      return put(output, 0x7e) if cp == 0x203e

      if (0xff61..0xff9f).includes?(cp)
        return put(output, 0x8e, cp - 0xff61 + 0xa1)
      end

      cp = 0xff0d if cp == 0x2212
      if pointer = @table[cp]?
        return put(output, pointer // 94 + 0xa1, pointer % 94 + 0xa1)
      end

      false
    end
  end

  struct Writer::EUCKR < Writer
    @table : Table::Reverse(UInt16) = Table.reverse("euc-kr", Table.new(Data::EUC_KR))

    def write(cp : Int32, output : IO) : Bool
      if cp < 128
        put(output, cp)
      elsif pointer = @table[cp]?
        put(output, pointer // 190 + 0x81, pointer % 190 + 0x41)
      else
        false
      end
    end
  end

  struct Writer::ISO2022JP < Writer
    def span_end(input : Bytes, position : Int32) : Int32
      while position < input.size
        byte = input[position]
        break if byte >= 128 || byte == 0x1b || byte == 0x0e || byte == 0x0f
        break if @state == 1 && (byte == 0x5c || byte == 0x7e)
        position += 1
      end
      position
    end

    def write_span(bytes : Bytes, output : IO) : Nil
      switch(0, output) unless @state == 0 || @state == 1
      output.write(bytes)
    end

    @table : Table::Reverse(UInt16) = Table.reverse("jis0208", Table.new(Data::JIS0208))

    @katakana : Table(UInt16) = Table.new(Data::ISO_2022_JP_KATAKANA)
    @state = 0 # ASCII, Roman, jis0208

    def finish(output : IO) : Nil
      switch(0, output)
    end

    private def switch(state : Int32, output : IO) : Nil
      return if @state == state

      case @state = state
      when 0 then put(output, 0x1b, 0x28, 0x42)
      when 1 then put(output, 0x1b, 0x28, 0x4a)
      when 2 then put(output, 0x1b, 0x24, 0x42)
      end
    end

    def write(cp : Int32, output : IO) : Bool
      if cp < 128
        # Controls are forbidden even when switching back from jis0208.
        return false if cp == 0x0e || cp == 0x0f || cp == 0x1b
        switch(0, output) unless @state == 0 || (@state == 1 && cp != 0x5c && cp != 0x7e)
        return put(output, cp)
      end

      if cp == 0xa5 || cp == 0x203e
        switch(1, output)
        return put(output, cp == 0xa5 ? 0x5c : 0x7e)
      end

      cp = 0xff0d if cp == 0x2212
      cp = @katakana.codepoint_at(cp - 0xff61) if (0xff61..0xff9f).includes?(cp)

      if pointer = @table[cp]?
        switch(2, output)
        return put(output, pointer // 94 + 0x21, pointer % 94 + 0x21)
      end

      # Defer transitions until the replacement is known. Returning to ASCII
      # and immediately entering JIS again would decode as a spurious error.
      false
    end
  end
end
