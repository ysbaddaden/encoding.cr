require "./reader"

module Encoding
  # Incrementally converts external bytes to valid UTF-8. Call finish once at EOF.
  class Decoder
    # :nodoc:
    enum State
      Active
      Finished
      Failed
    end

    getter encoding : Descriptor
    getter errors : ErrorMode
    getter bom : BOMPolicy
    getter replacement : String
    @requested : Descriptor
    @reader : Reader
    @prefix = uninitialized UInt8[4]
    @prefix_size = 0
    @resolved = false
    @state : State = :active

    def initialize(encoding : String = "utf-8", @errors : ErrorMode = :replace, @replacement : String = "\uFFFD", @bom : BOMPolicy = :detect)
      raise ArgumentError.new("Replacement must be valid UTF-8") unless @replacement.valid_encoding?
      @requested = @encoding = Encoding.find(encoding)
      @reader = Reader.for(@encoding.name)
      @resolved = @bom.preserve?
    end

    def feed(bytes : Bytes) : String
      String.build { |output| feed(bytes, output) }
    end

    def finish : String
      String.build { |output| finish(output) }
    end

    # Append UTF-8 to an existing output. A failure may leave partial output.
    def feed(bytes : Bytes, output : IO) : Nil
      run(bytes, false, output)
    end

    def finish(output : IO) : Nil
      run(Bytes.empty, true, output)
    end

    def reset : self
      @encoding = @requested
      @reader = Reader.for(@encoding.name)
      @prefix_size = 0
      @resolved = @bom.preserve?
      @state = :active
      self
    end

    private def run(bytes : Bytes, final : Bool, output : IO) : Nil
      raise StateError.new("Decoder is finished or failed; call reset") unless @state.active?
      begin
        if @resolved
          convert(bytes, final, output)
        else
          # Inspect only the initial prefix. Do not delay ordinary input until
          # four bytes have arrived, and never buffer the rest of the stream.
          consumed = 0

          while !@resolved && consumed < bytes.size
            @prefix[@prefix_size] = bytes[consumed]
            @prefix_size += 1
            consumed += 1
            resolve_bom(false)
          end

          if final && !@resolved
            resolve_bom(true)
          end

          if @resolved
            convert(@prefix.to_slice[0, @prefix_size], false, output)
            @prefix_size = 0
            convert(bytes[consumed..], final, output)
          end
        end

        @state = :finished if final
      rescue ex
        @state = :failed
        raise ex
      end
    end

    private def resolve_bom(final : Bool) : Nil
      possible = false
      matched_name = nil
      matched_size = 0

      BOM_SIGNATURES.each do |name, signature|
        next if @bom.strip? && name != @requested.name
        count = Math.min(@prefix_size, signature.size)
        next unless count.times.all? { |i| @prefix[i] == signature[i] }

        if @prefix_size < signature.size
          possible = true
        elsif signature.size > matched_size
          matched_name = name
          matched_size = signature.size
        end
      end

      # UTF-16LE's BOM is also a prefix of UTF-32LE's BOM. Wait until
      # disambiguated, or choose the complete shorter signature at EOF.
      return if possible && !final

      if name = matched_name
        @encoding = Encoding.find(name)
        @reader = Reader.for(name, matched_size.to_i64)
        @prefix_size -= matched_size
        @prefix_size.times { |i| @prefix[i] = @prefix[i + matched_size] }
      end
      @resolved = true
    end

    private def convert(bytes : Bytes, final : Bool, output : IO) : Nil
      @reader.process(bytes, final) do |data, offset|
        if data.is_a?(Bytes)
          output.write(data)
        elsif data < 0
          raise InvalidByteSequenceError.new("Malformed byte sequence", @encoding.name, offset) if @errors.strict?
          output << @replacement
        else
          output << data.chr
        end
      end
    end
  end
end
