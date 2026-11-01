require "./writer"

module Encoding
  # Incrementally converts UTF-8 strings or byte chunks to the target encoding.
  class Encoder
    # :nodoc:
    enum State
      Initial
      Active
      Finished
      Failed
    end

    getter encoding : Descriptor
    getter errors : ErrorMode
    getter replacement : String
    getter? bom : Bool
    @replacement_bytes : Bytes?
    @writer : Writer
    @iterator = UTF8.new
    @state : State = :initial

    def initialize(encoding : String = "utf-8", @errors : ErrorMode = :replace, @replacement : String = "?", @bom : Bool = false)
      @encoding = Encoding.find(encoding)

      unless @encoding.can_encode?
        raise UnsupportedEncodingError.new("No encoder for #{@encoding.name}")
      end

      if @bom && !{"UTF-8", "UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE"}.includes?(@encoding.name)
        raise ArgumentError.new("BOM emission requires UTF-8, UTF-16, or UTF-32")
      end

      unless @replacement.valid_encoding?
        raise ArgumentError.new("Replacement must be valid UTF-8")
      end

      @writer = Writer.for(@encoding.name)
      name = @encoding.name

      if @replacement.empty? || @encoding.name == "UTF-8" || (@replacement.ascii_only? && !@encoding.name.in?("UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE", "ISO-2022-JP"))
        # fast-path: can use the replacement as-is
        @replacement_bytes = @replacement.to_slice
        return
      end

      # slow-path: encode replacement once and validate that it can be
      # represented in the destination encoding
      output = IO::Memory.new

      @replacement.each_codepoint do |cp|
        unless @writer.write(cp, output)
          raise ArgumentError.new("Replacement is not representable in #{@encoding.name}")
        end
      end

      if @encoding.name == "ISO-2022-JP"
        # ISO-2022-JP output depends on the live state, so encode its
        # replacement on demand. Finish restores the validation writer to ASCII.
        @writer.finish(output)
        @replacement_bytes = nil
      else
        @replacement_bytes = output.to_slice
      end
    end

    def feed(text : String) : Bytes
      feed(text.to_slice)
    end

    def feed(bytes : Bytes) : Bytes
      output = IO::Memory.new
      feed(bytes, output)
      output.to_slice
    end

    def finish : Bytes
      output = IO::Memory.new
      finish(output)
      output.to_slice
    end

    # Append to an existing output. A failure may leave partial output.
    def feed(text : String, output : IO) : Nil
      feed(text.to_slice, output)
    end

    def feed(bytes : Bytes, output : IO) : Nil
      run(bytes, false, output)
    end

    def finish(output : IO) : Nil
      run(Bytes.empty, true, output)
    end

    def reset : self
      @writer = Writer.for(@encoding.name)
      @iterator = UTF8.new
      @state = :initial
      self
    end

    private def run(bytes : Bytes, final : Bool, output : IO) : Nil
      unless @state.initial? || @state.active?
        raise StateError.new("Encoder is finished or failed; call reset")
      end

      begin
        if @state.initial?
          write_bom(output) if @bom
          @state = :active
        end
        convert(bytes, final, output)
        if final
          @writer.finish(output)
          @state = :finished
        end
      rescue ex
        @state = :failed
        raise ex
      end
    end

    private def write_bom(output)
      BOM_SIGNATURES.each do |name, signature|
        next unless name == @encoding.name

        signature.each { |byte| output.write_byte(byte) }
        return
      end
    end

    private def convert(bytes : Bytes, final : Bool, output : IO) : Nil
      @iterator.process(bytes, final, ascii_prefix: !@writer.is_a?(Writer::UTF8)) do |data, offset|
        if data.is_a?(Bytes)
          ending = @writer.span_end(data, 0)
          @writer.write_span(data[0, ending], output) if ending > 0
          ending
        else
          if data < 0
            raise InvalidByteSequenceError.new("Malformed UTF-8 input", @encoding.name, offset) if @errors.strict?
            replace(output)
          elsif !@writer.write(data, output)
            raise UndefinedConversionError.new("Unrepresentable U+#{data.to_s(16, upcase: true)}", @encoding.name, offset) if @errors.strict?
            replace(output)
          end
          0
        end
      end
    end

    private def replace(output : IO) : Nil
      if bytes = @replacement_bytes
        output.write(bytes)
      else
        @replacement.each_codepoint { |cp| @writer.write(cp, output) }
      end
    end
  end
end
