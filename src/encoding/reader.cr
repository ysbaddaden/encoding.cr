require "./utf8"

module Encoding
  # A token parser shared by one-shot, incremental, and IO conversion. Only an
  # incomplete token (at most three bytes) survives a call. -1 denotes an error.
  private abstract struct Reader
    def initialize(offset : Int64 = 0)
      @cursor = IncrementalCursor.new(offset)
    end

    alias Token = Tuple(Int32, Int32?, Int32?)

    WAIT_TOKEN = {0, nil, nil}

    # Resolve the encoding once, before entering the token loop.
    def self.for(name : String, offset : Int64 = 0) : Reader
      if table = Table.single_byte?(name)
        return SingleByte.new(table, offset)
      end

      case name
      when "UTF-8"          then UTF8.new(offset)
      when "UTF-16LE"       then UTF16LE.new(offset)
      when "UTF-16BE"       then UTF16BE.new(offset)
      when "GBK"            then Chinese.new(offset)
      when "gb18030"        then Chinese.new(offset)
      when "Big5"           then Big5.new(offset)
      when "Shift_JIS"      then ShiftJIS.new(offset)
      when "EUC-JP"         then EUCJP.new(offset)
      when "EUC-KR"         then EUCKR.new(offset)
      when "ISO-2022-JP"    then ISO2022JP.new(offset)
      when "x-user-defined" then UserDefined.new(offset)
      when "replacement"    then Replacement.new(offset)
      else
        raise UnsupportedEncodingError.new("No decoder for #{name}")
      end
    end

    # Spans are borrowed and valid only for the duration of the callback.
    def process(bytes : Bytes, final : Bool, &block : Bytes | Int32, Int64 ->) : Nil
      @cursor.each_input(bytes, final) do |at_end|
        while @cursor.remaining > 0
          ending = span_end

          if ending > @cursor.position
            yield @cursor.input[@cursor.position, ending - @cursor.position], @cursor.offset + @cursor.position
            @cursor.position = ending
            next
          end

          count, cp, second = step(at_end)
          break if count == 0

          at = @cursor.offset + @cursor.position
          yield cp, at unless cp.nil?
          yield second, at unless second.nil?

          @cursor.position += count
        end
      end
    end

    private def span_end : Int32
      ASCII.end_of_run(@cursor.input, @cursor.position)
    end

    private def b(i = 0) : Int32
      @cursor.input[@cursor.position + i].to_i
    end

    private def token(count : Int32, cp : Int32? = nil, second : Int32? = nil) : Token
      {count, cp, second}
    end

    private def incomplete(final : Bool) : Token
      if final
        token(@cursor.remaining, -1)
      else
        WAIT_TOKEN
      end
    end

    private abstract def step(final : Bool) : Token
  end

  struct Reader::SingleByte < Reader
    @table : Table(UInt16)

    def initialize(@table : Table(UInt16), offset : Int64 = 0)
      super(offset)
    end

    private def step(final : Bool) : Token
      byte = b
      token(1, byte < 128 ? byte : @table.codepoint_at(byte - 128))
    end
  end

  struct Reader::UserDefined < Reader
    private def step(final : Bool) : Token
      byte = b
      token(1, byte < 128 ? byte : byte + 0xf700)
    end
  end

  struct Reader::Replacement < Reader
    private def span_end : Int32
      @cursor.position
    end

    @replacement_seen = false

    private def step(final : Bool) : Token
      cp = @replacement_seen ? nil : -1
      @replacement_seen = true
      token(@cursor.remaining, cp)
    end
  end

  struct Reader::UTF8 < Reader
    @iterator : Encoding::UTF8

    def initialize(offset : Int64 = 0)
      super(offset)
      @iterator = Encoding::UTF8.new(offset)
    end

    def process(bytes : Bytes, final : Bool, &block : Bytes | Int32, Int64 ->) : Nil
      @iterator.process(bytes, final) do |data, offset|
        yield data, offset
        data.is_a?(Bytes) ? data.size : 0
      end
    end

    private def step(final : Bool) : Token
      WAIT_TOKEN
    end
  end

  abstract struct Reader::UTF16 < Reader
    private def span_end : Int32
      @cursor.position
    end

    private abstract def unit(i : Int32) : Int32

    private def step(final : Bool) : Token
      return incomplete(final) if @cursor.remaining < 2

      first = unit(0)
      if (0xd800..0xdbff).includes?(first)
        return incomplete(final) if @cursor.remaining < 4

        second = unit(2)
        return token(2, -1) unless (0xdc00..0xdfff).includes?(second)

        token(4, 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00)
      elsif (0xdc00..0xdfff).includes?(first)
        token(2, -1)
      else
        token(2, first)
      end
    end
  end

  struct Reader::UTF16LE < Reader::UTF16
    private def unit(i : Int32) : Int32
      (b(i + 1) << 8) | b(i)
    end
  end

  struct Reader::UTF16BE < Reader::UTF16
    private def unit(i : Int32) : Int32
      (b(i) << 8) | b(i + 1)
    end
  end

  struct Reader::Chinese < Reader
    @table : Table(UInt16) = Table.new(Data::GB18030)

    private def step(final : Bool) : Token
      first = b
      return token(1, first) if first < 128
      return token(1, 0x20ac) if first == 0x80
      return token(1, -1) unless (0x81..0xfe).includes?(first)
      return incomplete(final) if @cursor.remaining < 2

      second = b(1)
      if (0x30..0x39).includes?(second)
        return incomplete(final) if @cursor.remaining < 3

        third = b(2)
        return token(1, -1) unless (0x81..0xfe).includes?(third)
        return incomplete(final) if @cursor.remaining < 4

        fourth = b(3)
        return token(1, -1) unless (0x30..0x39).includes?(fourth)

        pointer = (first - 0x81) * 12600 + (second - 0x30) * 1260 + (third - 0x81) * 10 + fourth - 0x30
        return token(4, range_codepoint(pointer))
      end

      cp = -1
      if (0x40..0x7e).includes?(second) || (0x80..0xfe).includes?(second)
        cp = @table.codepoint_at((first - 0x81) * 190 + second - (second < 0x7f ? 0x40 : 0x41))
      end

      token(cp < 0 && second < 128 ? 1 : 2, cp)
    end

    protected def range_codepoint(pointer : Int32) : Int32
      return -1 if (39420...189000).includes?(pointer) || pointer > 1237575
      return 0xe7c7 if pointer == 7457

      lower = 0
      upper = Data::GB18030_RANGES.size

      while lower < upper
        middle = lower + (upper - lower) // 2

        if Data::GB18030_RANGES[middle][0] <= pointer
          lower = middle + 1
        else
          upper = middle
        end
      end

      pair = Data::GB18030_RANGES[Math.max(0, lower - 1)]
      pair[1] + pointer - pair[0]
    end
  end

  struct Reader::Big5 < Reader
    @table : Table(Int32) = Table.new(Data::BIG5)

    private def step(final : Bool) : Token
      first = b
      return token(1, first) if first < 128
      return token(1, -1) unless (0x81..0xfe).includes?(first)
      return incomplete(final) if @cursor.remaining < 2

      second = b(1)
      cp = -1

      if (0x40..0x7e).includes?(second) || (0xa1..0xfe).includes?(second)
        case pointer = (first - 0x81) * 157 + second - (second < 0x7f ? 0x40 : 0x62)
        when 1133 then return token(2, 0xca, 0x304)
        when 1135 then return token(2, 0xca, 0x30c)
        when 1164 then return token(2, 0xea, 0x304)
        when 1166 then return token(2, 0xea, 0x30c)
        end
        cp = @table.codepoint_at(pointer)
      end
      token(cp < 0 && second < 128 ? 1 : 2, cp)
    end
  end

  struct Reader::ShiftJIS < Reader
    @table : Table(UInt16) = Table.new(Data::JIS0208)

    private def step(final : Bool) : Token
      first = b
      return token(1, first) if first <= 0x80
      return token(1, first - 0xa1 + 0xff61) if (0xa1..0xdf).includes?(first)
      return token(1, -1) unless (0x81..0x9f).includes?(first) || (0xe0..0xfc).includes?(first)
      return incomplete(final) if @cursor.remaining < 2

      second = b(1)
      cp = -1
      if (0x40..0x7e).includes?(second) || (0x80..0xfc).includes?(second)
        pointer = (first - (first < 0xa0 ? 0x81 : 0xc1)) * 188 + second - (second < 0x7f ? 0x40 : 0x41)
        cp = (8836..10715).includes?(pointer) ? 0xe000 + pointer - 8836 : @table.codepoint_at(pointer)
      end
      token(cp < 0 && second < 128 ? 1 : 2, cp)
    end
  end

  struct Reader::EUCJP < Reader
    @jis0208 : Table(UInt16) = Table.new(Data::JIS0208)
    @jis0212 : Table(UInt16) = Table.new(Data::JIS0212)

    private def step(final : Bool) : Token
      first = b
      return token(1, first) if first < 128
      return token(1, -1) unless first == 0x8e || first == 0x8f || (0xa1..0xfe).includes?(first)
      return incomplete(final) if @cursor.remaining < 2

      second = b(1)
      if first == 0x8e && (0xa1..0xdf).includes?(second)
        return token(2, second - 0xa1 + 0xff61)
      end

      if first == 0x8f && (0xa1..0xfe).includes?(second)
        return incomplete(final) if @cursor.remaining < 3

        third = b(2)
        cp = if (0xa1..0xfe).includes?(third)
               @jis0212.codepoint_at((second - 0xa1) * 94 + third - 0xa1)
             else
               -1
             end
        return token(cp < 0 && third < 128 ? 2 : 3, cp)
      end

      cp = if (0xa1..0xfe).includes?(first) && (0xa1..0xfe).includes?(second)
             @jis0208.codepoint_at((first - 0xa1) * 94 + second - 0xa1)
           else
             -1
           end
      token(cp < 0 && second < 128 ? 1 : 2, cp)
    end
  end

  struct Reader::EUCKR < Reader
    @table : Table(UInt16) = Table.new(Data::EUC_KR)

    private def step(final : Bool) : Token
      first = b
      return token(1, first) if first < 128
      return token(1, -1) unless (0x81..0xfe).includes?(first)
      return incomplete(final) if @cursor.remaining < 2

      second = b(1)
      cp = if (0x41..0xfe).includes?(second)
             @table.codepoint_at((first - 0x81) * 190 + second - 0x41)
           else
             -1
           end
      token(cp < 0 && second < 128 ? 1 : 2, cp)
    end
  end

  struct Reader::ISO2022JP < Reader
    private def span_end : Int32
      return @cursor.position unless @iso_state == 0 || @iso_state == 1

      ending = @cursor.position
      while ending < @cursor.input.size
        byte = @cursor.input[ending]
        break if byte >= 128 || byte == 0x1b || byte == 0x0e || byte == 0x0f
        break if @iso_state == 1 && (byte == 0x5c || byte == 0x7e)
        ending += 1
      end

      @iso_output = false if ending > @cursor.position
      ending
    end

    @table : Table(UInt16) = Table.new(Data::JIS0208)

    @iso_state = 0 # ASCII, Roman, katakana, jis0208
    @iso_output = false

    private def step(final : Bool) : Token
      first = b
      if first == 0x1b
        if @cursor.remaining < 2
          return WAIT_TOKEN unless final
        elsif b(1) == 0x24 || b(1) == 0x28
          return WAIT_TOKEN if @cursor.remaining < 3 && !final

          if @cursor.remaining >= 3
            state = case {b(1), b(2)}
                    when {0x28, 0x42}               then 0
                    when {0x28, 0x4a}               then 1
                    when {0x28, 0x49}               then 2
                    when {0x24, 0x40}, {0x24, 0x42} then 3
                    else                                 -1
                    end
            if state >= 0
              @iso_state = state
              cp = @iso_output ? -1 : nil
              @iso_output = true
              return token(3, cp)
            end
          end
        end

        @iso_output = false
        return token(1, -1)
      end

      @iso_output = false
      case @iso_state
      when 0, 1
        return token(1, -1) if first > 127 || first == 0x0e || first == 0x0f
        return token(1, 0xa5) if @iso_state == 1 && first == 0x5c
        return token(1, 0x203e) if @iso_state == 1 && first == 0x7e
        token(1, first)
      when 2
        token(1, (0x21..0x5f).includes?(first) ? first - 0x21 + 0xff61 : -1)
      else
        return token(1, -1) unless (0x21..0x7e).includes?(first)
        return incomplete(final) if @cursor.remaining < 2

        second = b(1)
        return token(1, -1) if second == 0x1b

        cp = if (0x21..0x7e).includes?(second)
               @table.codepoint_at((first - 0x21) * 94 + second - 0x21)
             else
               -1
             end
        token(2, cp)
      end
    end
  end
end
