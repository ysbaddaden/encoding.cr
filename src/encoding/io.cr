require "./decoder"
require "./encoder"

module Encoding
  # :nodoc:
  #
  # A readable IO whose bytes are UTF-8. Closing does not drain unread input.
  class DecoderIO < IO
    @codec : Encoding::Decoder
    @buffer = Bytes.new(4096)
    @converted = IO::Memory.new
    @output = Bytes.empty
    @position = 0
    @eof = false
    @failed = false
    @closed = false

    def initialize(@io : IO, encoding : String = "utf-8", *, @close_underlying : Bool = false, errors : ErrorMode = :replace,
                   replacement : String = "\uFFFD", bom : BOMPolicy = :detect)
      @codec = Encoding::Decoder.new(encoding, errors: errors, replacement: replacement, bom: bom)
    end

    def read(slice : Bytes) : Int32
      check_open
      raise StateError.new("DecoderIO is failed") if @failed
      return 0 if slice.empty?
      begin
        while @position == @output.size
          return 0 if @eof
          count = @io.read(@buffer)
          @converted.clear
          if count == 0
            @eof = true
            @codec.finish(@converted)
          else
            @codec.feed(@buffer[0, count], @converted)
          end
          @output = @converted.to_slice
          @position = 0
        end
        count = Math.min(slice.size, @output.size - @position)
        slice.copy_from(@output[@position, count])
        @position += count
        count
      rescue ex
        @failed = true
        raise ex
      end
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("DecoderIO is read-only")
    end

    def close : Nil
      return if @closed
      @closed = true
      @io.close if @close_underlying
    end

    def closed? : Bool
      @closed
    end
  end

  # :nodoc:
  #
  # A writable IO accepting UTF-8 bytes. Flush preserves conversion state;
  # finish finalizes it without closing either IO. Close calls finish once.
  class EncoderIO < IO
    @converted = IO::Memory.new
    @codec : Encoding::Encoder
    @finished = false
    @closed = false
    @failed = false

    def initialize(@io : IO, encoding : String = "utf-8", *, @close_underlying : Bool = false, errors : ErrorMode = :replace,
                   replacement : String = "?", bom : Bool = false)
      @codec = Encoding::Encoder.new(encoding, errors: errors, replacement: replacement, bom: bom)
    end

    def write(slice : Bytes) : Nil
      check_open
      raise StateError.new("EncoderIO is finished or failed") if @finished || @failed
      begin
        position = 0
        while position < slice.size
          count = Math.min(4096, slice.size - position)
          @converted.clear
          @codec.feed(slice[position, count], @converted)
          @io.write(@converted.to_slice)
          position += count
        end
      rescue ex
        @failed = true
        raise ex
      end
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("EncoderIO is write-only")
    end

    def flush : Nil
      check_open
      raise StateError.new("EncoderIO is failed") if @failed
      begin
        @io.flush
      rescue ex
        @failed = true
        raise ex
      end
    end

    def finish : Nil
      check_open
      return if @finished
      raise StateError.new("EncoderIO is failed") if @failed
      begin
        @converted.clear
        @codec.finish(@converted)
        @io.write(@converted.to_slice)
        @io.flush
        @finished = true
      rescue ex
        @failed = true
        raise ex
      end
    end

    def close : Nil
      return if @closed
      begin
        finish unless @failed
      ensure
        @closed = true
        @io.close if @close_underlying
      end
    end

    def closed? : Bool
      @closed
    end
  end
end
