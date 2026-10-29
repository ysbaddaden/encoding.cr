module Encoding
  class Error < Exception
  end

  class UnknownEncodingError < Error
  end

  class UnsupportedEncodingError < Error
  end

  class StateError < Error
  end

  class ConversionError < Error
    getter encoding : String
    getter offset : Int64

    def initialize(message : String, @encoding : String, @offset : Int64)
      super("#{message} in #{@encoding} at input byte #{@offset}")
    end
  end

  class InvalidByteSequenceError < ConversionError
  end

  class UndefinedConversionError < ConversionError
  end
end
