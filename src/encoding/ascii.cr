module Encoding
  private module ASCII
    def self.end_of_run(input : Bytes, position : Int32) : Int32
      while position < input.size && input[position] < 128
        position += 1
      end
      position
    end
  end
end
