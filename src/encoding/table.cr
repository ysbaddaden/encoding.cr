module Encoding
  # A literal forward mapping of encoding pointers to Unicode codepoints.
  # Undefined entries are 0xffff in UInt16 tables and -1 in Int32 tables.
  private struct Table(T)
    def initialize(@data : Slice(T))
    end

    def size : Int32
      @data.size
    end

    def self.single_byte?(name : String) : Table(UInt16)?
      if data = Data::SINGLE_BYTE_INDEXES[index_name(name)]?
        Table.new(data)
      end
    end

    def self.for?(name : String) : Table(UInt16) | Table(Int32) | Nil
      case index_name(name)
      when "big5"                 then Table.new(Data::BIG5)
      when "gb18030"              then Table.new(Data::GB18030)
      when "jis0208"              then Table.new(Data::JIS0208)
      when "jis0212"              then Table.new(Data::JIS0212)
      when "euc-kr"               then Table.new(Data::EUC_KR)
      when "iso-2022-jp-katakana" then Table.new(Data::ISO_2022_JP_KATAKANA)
      else                             single_byte?(name)
      end
    end

    def self.for(name : String) : Table(UInt16) | Table(Int32)
      for?(name) || raise NilAssertionError.new("Expected encoding table for #{name} but got nil")
    end

    def self.index_name(name : String) : String
      case name
      when "ISO-8859-8-I" then "iso-8859-8"
      when "GBK"          then "gb18030"
      else                     name.downcase(:ascii)
      end
    end

    def codepoint_at(pointer : Int32) : Int32
      value = @data[pointer]? if pointer >= 0
      {% if T == UInt16 %}
        value.nil? || value == 0xffff ? -1 : value.to_i32
      {% else %}
        value.nil? ? -1 : value.to_i32
      {% end %}
    end

    # Reverse pointers are bytes for single-byte encodings and UInt16 otherwise.
    # The maximum value marks an unmapped codepoint.
    struct Reverse(P)
      getter data : Slice(P)

      def initialize(size : Int32)
        @data = Slice(P).new(size, P::MAX)
      end

      def []?(cp : Int32) : Int32?
        return unless cp >= 0

        pointer = @data[cp]?
        pointer.nil? || pointer == P::MAX ? nil : pointer.to_i32
      end

      def []=(cp : Int32, pointer : Int32) : Int32
        raise "Reverse pointer exceeds #{P}" unless 0 <= pointer < P::MAX

        @data[cp] = P.new(pointer)
        pointer
      end

      def self.build(name : String, index : Table(U)) : Reverse(P) forall U
        maximum = -1

        # precalculate table size
        index.size.times do |pointer|
          next if name == "shift_jis" && (8272..8835).includes?(pointer)
          next if name == "big5" && pointer < 5024
          maximum = Math.max(maximum, index.codepoint_at(pointer))
        end

        # generate the reverse table from the forward table
        reverse = new(maximum + 1)

        index.size.times do |pointer|
          next if name == "shift_jis" && (8272..8835).includes?(pointer)
          next if name == "big5" && pointer < 5024

          cp = index.codepoint_at(pointer)
          next if cp < 0

          if name == "big5" && {0x2550, 0x255e, 0x2561, 0x256a, 0x5341, 0x5345}.includes?(cp)
            reverse[cp] = pointer
          else
            reverse[cp] ||= pointer
          end
        end

        reverse
      end
    end

    @@reverse = Hash(String, Reverse(UInt8) | Reverse(UInt16)).new(initial_capacity: Data::SIZE)
    @@reverse_lock = Sync::MU.new

    def self.reverse(name : String) : Reverse(UInt8) | Reverse(UInt16)
      if index = single_byte?(name)
        return reverse(name, index, UInt8)
      end
      case index = for(name == "shift_jis" ? "jis0208" : name)
      when Table(UInt16) then reverse(name, index)
      when Table(Int32)  then reverse(name, index)
      else                    raise "Unexpected encoding table type"
      end
    end

    def self.reverse(name : String, index : Table(U)) : Reverse(UInt16) forall U
      reverse(name, index, UInt16)
    end

    def self.reverse(name : String, index : Table(U), pointer_type : P.class) : Reverse(P) forall U, P
      name = index_name(name)

      @@reverse_lock.rlock
      begin
        reverse = @@reverse[name]?
      ensure
        @@reverse_lock.runlock
      end

      if reverse.nil?
        @@reverse_lock.lock
        begin
          reverse = @@reverse[name] ||= Reverse(P).build(name, index)
        ensure
          @@reverse_lock.unlock
        end
      end

      reverse.as(Reverse(P))
    end
  end
end
