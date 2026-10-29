module Encoding
  # Tracks a byte offset across input chunks, retaining only an incomplete suffix.
  # The current chunk is borrowed only for the duration of each_input.
  private struct IncrementalCursor
    @pending = uninitialized UInt8[4]
    @pending_size = 0
    getter input = Bytes.empty
    property position = 0
    getter offset : Int64 = 0

    def initialize(@offset : Int64 = 0)
    end

    def each_input(bytes : Bytes, final : Bool, & : Bool ->) : Nil
      cursor = 0

      loop do
        if @pending_size > 0
          # Join only the incomplete token to the next few bytes. The rest of
          # the caller's chunk is parsed directly, without copying it.
          count = Math.min(@pending.size - @pending_size, bytes.size - cursor)
          @pending.to_slice[@pending_size, count].copy_from(bytes[cursor, count])
          cursor += count
          @input = @pending.to_slice[0, @pending_size + count]
        else
          @input = bytes[cursor..]
          cursor = bytes.size
        end

        @position = 0
        yield final && cursor == bytes.size

        @offset += @position
        @pending_size = remaining
        @pending_size.times { |i| @pending[i] = @input[@position + i] }

        break if cursor == bytes.size
      end
    ensure
      # Do not retain the caller's input between feed calls, even on failure.
      @input = Bytes.empty
    end

    def remaining : Int32
      @input.size - @position
    end
  end
end
