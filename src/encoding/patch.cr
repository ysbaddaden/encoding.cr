require "../encoding"
require "weak_ref"

class String
  # :nodoc:
  def self.encode(slice, from, to, io, invalid)
    IO::EncodingOptions.check_invalid(invalid)
    errors = invalid == :skip ? ::Encoding::ErrorMode::Replace : ::Encoding::ErrorMode::Strict
    decoder = ::Encoding::Decoder.new(from, errors: errors, replacement: "", bom: :preserve)
    encoder = ::Encoding::Encoder.new(to, errors: errors, replacement: "")
    position = 0
    while position < slice.size
      count = Math.min(4096, slice.size - position)
      encoder.feed(decoder.feed(slice[position, count]), io)
      position += count
    end
    encoder.feed(decoder.finish, io)
    encoder.finish(io)
  rescue ex : ::Encoding::Error
    raise ArgumentError.new(ex.message)
  end
end

class IO
  private class Encoder
    @codec : ::Encoding::Encoder
    # The IO owns its encoder. A strong reference back to it would create a
    # finalization cycle for IOs such as sockets and files.
    @io : WeakRef(IO)?
    @closed = false

    def initialize(@encoding_options : EncodingOptions)
      options = @encoding_options
      errors = options.invalid == :skip ? ::Encoding::ErrorMode::Replace : ::Encoding::ErrorMode::Strict
      @codec = begin
        ::Encoding::Encoder.new(options.name, errors: errors, replacement: "")
      rescue ex : ::Encoding::Error
        raise ArgumentError.new(ex.message)
      end
    end

    def write(io : IO, slice : Bytes) : Nil
      @io ||= WeakRef(IO).new(io)
      @codec.feed(slice, io)
    rescue ex : ::Encoding::Error
      raise ArgumentError.new(ex.message)
    end

    def close : Nil
      return if @closed
      @closed = true
      if io = @io.try(&.value)
        @codec.finish(io)
      end
    rescue ex : ::Encoding::Error
      raise ArgumentError.new(ex.message)
    end
  end

  private class Decoder
    @codec : ::Encoding::Decoder
    # The codec retains partial input, so the stdlib input cursor is unused.
    {% unless flag?(:without_iconv) %}
      @in_buffer = Pointer(UInt8).null
    {% end %}
    @converted = IO::Memory.new
    @out_slice = Bytes.empty
    @closed = false

    {% if flag?(:without_iconv) %}
      property out_slice : Bytes
    {% end %}

    def initialize(@encoding_options : EncodingOptions)
      options = @encoding_options
      errors = options.invalid == :skip ? ::Encoding::ErrorMode::Replace : ::Encoding::ErrorMode::Strict
      @codec = begin
        ::Encoding::Decoder.new(options.name, errors: errors, replacement: "", bom: :preserve)
      rescue ex : ::Encoding::Error
        raise ArgumentError.new(ex.message)
      end
      @buffer = Bytes.new(4096)
    end

    def read(io : IO) : Nil
      while @out_slice.empty? && !@closed
        count = io.read(@buffer)
        @converted.clear
        if count == 0
          @closed = true
          @codec.finish(@converted)
        else
          @codec.feed(@buffer[0, count], @converted)
        end
        @out_slice = @converted.to_slice
      end
    rescue ex : ::Encoding::Error
      raise ArgumentError.new(ex.message)
    end

    # With iconv enabled, reuse the stdlib buffer consumers unchanged.
    {% if flag?(:without_iconv) %}
      def read_byte(io : IO) : UInt8?
        read(io)
        if out_slice.empty?
          nil
        else
          byte = out_slice.to_unsafe.value
          advance 1
          byte
        end
      end

      def read_utf8(io : IO, slice : Bytes) : Int32
        count = 0
        until slice.empty?
          read(io)
          break if out_slice.empty?

          available = Math.min(out_slice.size, slice.size)
          out_slice[0, available].copy_to(slice.to_unsafe, available)
          advance(available)
          count += available
          slice += available
        end
        count
      end

      def gets(io : IO, delimiter : UInt8, limit : Int, chomp : Bool) : String?
        read(io)
        return nil if @out_slice.empty?

        index = @out_slice.index(delimiter)
        if index
          # If we find it past the limit, limit the result
          if index >= limit
            index = limit
          else
            index += 1
          end

          return gets_index(index, delimiter, chomp)
        end

        # Check if there's limit bytes in the out slice
        if @out_slice.size >= limit
          return gets_index(limit, delimiter, chomp)
        end

        # We need to read from the out_slice into a String until we find that byte,
        # or until we consumed limit bytes
        String.build do |str|
          loop do
            limit -= @out_slice.size
            write str

            read(io)

            break if @out_slice.empty?

            index = @out_slice.index(delimiter)
            if index
              if index >= limit
                index = limit
              else
                index += 1
              end
              write str, index
              break
            else
              if limit < @out_slice.size
                write(str, limit)
                break
              end
            end
          end
          str.chomp!(delimiter) if chomp
        end
      end

      private def gets_index(index, delimiter, chomp)
        advance_increment = index

        if chomp && index > 0 && @out_slice[index - 1] === delimiter
          index -= 1

          if delimiter === '\n' && index > 0 && @out_slice[index - 1] === '\r'
            index -= 1
          end
        end

        string = String.new(@out_slice[0, index])
        advance(advance_increment)
        string
      end

      def write(io : IO) : Nil
        io.write @out_slice
        @out_slice = Bytes.empty
      end

      def write(io : IO, numbytes : Int) : Nil
        io.write @out_slice[0, numbytes]
        @out_slice += numbytes
      end

      def advance(numbytes : Int) : Nil
        @out_slice += numbytes
      end
    {% end %}

    def close : Nil
      @closed = true
      @out_slice = Bytes.empty
    end
  end
end

{% if flag?(:without_iconv) %}
  class IO::Memory
    def to_s : String
      if encoding = @encoding
        String.new(to_slice, encoding.name, encoding.invalid)
      else
        String.new(@buffer, @bytesize)
      end
    end

    def to_s(io : IO) : Nil
      increase_capacity_by(bytesize) if io == self
      if encoding = @encoding
        String.encode(to_slice, encoding.name, io.encoding, io, io.@encoding.try(&.invalid))
      else
        io.write(to_slice)
      end
    end
  end
{% end %}
