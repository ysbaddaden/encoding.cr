require "./ascii"
require "./incremental_cursor"

module Encoding
  # :nodoc:
  struct UTF8
    @cursor : IncrementalCursor

    def initialize(offset : Int64 = 0)
      @cursor = IncrementalCursor.new(offset)
    end

    # Validation and maximal-subpart recovery share the incremental cursor.
    # Spans are borrowed for the callback only.
    #
    # Return the bulk-consumed byte count for spans (zero for scalar/error
    # events); remaining scalars are decoded internally and emitted with
    # their original source offsets.
    #
    # With *ascii_prefix*, the consumer first sees unvalidated input and must
    # consume only a destination-safe ASCII prefix. Remaining input still goes
    # through UTF-8 validation before scalar decoding.
    def process(bytes : Bytes, final : Bool, ascii_prefix : Bool = false, &block : Bytes | Int32, Int64 -> Int32) : Nil
      @cursor.each_input(bytes, final) do |at_end|
        while @cursor.remaining > 0
          if ascii_prefix
            count = yield @cursor.input[@cursor.position..], @cursor.offset + @cursor.position
            if count > 0
              @cursor.position += count
              next
            end
          end

          ending = UTF8.end_of_run(@cursor.input, @cursor.position)

          if ending > @cursor.position
            while @cursor.position < ending
              # Consumers may bulk-write a prefix. Decode the next scalar in
              # the unconsumed remainder here, without validating it again.
              count = yield @cursor.input[@cursor.position, ending - @cursor.position], @cursor.offset + @cursor.position
              @cursor.position += count

              if @cursor.position < ending
                cp, size = scalar(@cursor.input, @cursor.position)
                yield cp, @cursor.offset + @cursor.position
                @cursor.position += size
              end
            end
          else
            count = UTF8.invalid_size(@cursor.input, @cursor.position, at_end)
            break if count == 0

            yield -1, @cursor.offset + @cursor.position
            @cursor.position += count
          end
        end
      end
    end

    # Decode a scalar from a validated span, without another validation pass.
    private def scalar(input : Bytes, position : Int32) : Tuple(Int32, Int32)
      first = input[position].to_i
      return {first, 1} if first < 128

      size = first < 0xe0 ? 2 : (first < 0xf0 ? 3 : 4)
      cp = first & (0x7f >> size)
      (1...size).each { |i| cp = (cp << 6) | (input[position + i] & 0x3f).to_i }
      {cp, size}
    end

    # Called at a sequence rejected by end_of_run. Consume its maximal
    # subpart, or wait if it can still be completed by the next chunk.
    def self.invalid_size(input : Bytes, position : Int32, final : Bool) : Int32
      first = input[position]
      size = case first
             when 0xc2..0xdf then 2
             when 0xe0..0xef then 3
             when 0xf0..0xf4 then 4
             else                 return 1
             end

      (1...size).each do |i|
        return final ? i : 0 if position + i >= input.size

        lower = i == 1 && first == 0xe0 ? 0xa0 : (i == 1 && first == 0xf0 ? 0x90 : 0x80)
        upper = i == 1 && first == 0xed ? 0x9f : (i == 1 && first == 0xf4 ? 0x8f : 0xbf)
        return i unless lower <= input[position + i] <= upper
      end

      size
    end

    # Stop before an invalid or incomplete sequence; process then emits a
    # maximal-subpart error or retains the incomplete suffix.
    def self.end_of_run(input : Bytes, position : Int32) : Int32
      while position < input.size
        first = input[position]
        break if first > 0xf4

        if first < 128
          position = ASCII.end_of_run(input, position)
          next
        end
        break if first < 0xc2

        size = first < 0xe0 ? 2 : (first < 0xf0 ? 3 : 4)
        break if input.size - position < size

        lower = first == 0xe0 ? 0xa0 : (first == 0xf0 ? 0x90 : 0x80)
        upper = first == 0xed ? 0x9f : (first == 0xf4 ? 0x8f : 0xbf)
        second = input[position + 1]
        break unless lower <= second <= upper
        break if size >= 3 && !(0x80..0xbf).includes?(input[position + 2])
        break if size == 4 && !(0x80..0xbf).includes?(input[position + 3])

        position += size
      end

      position
    end
  end
end
