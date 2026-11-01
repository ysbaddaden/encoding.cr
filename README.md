# encoding.cr

Pure Crystal conversion between external character encodings and UTF-8. There
are no dependencies (Shards or C libraries).

Mappings and codec algorithms follow the [WHATWG Encoding Standard]. The initial
charset set is the standard's set, with UTF-16 and UTF-32 added as extensions.

## Usage

Add the shard's repository to your `shard.yml` dependencies:

```yaml
dependencies:
  encoding:
    github: ysbaddaden/encoding.cr
```

```crystal
require "encoding"

Encoding.decode(Bytes[0x63, 0x61, 0x66, 0xe9], "windows-1252") # => "café"
Encoding.encode("日本語", "shift_jis") # => Bytes[0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea]

charset = Encoding.find(" ASCII ")
charset.name # => "windows-1252"
charset.can_encode? # => true
Encoding.encodings # descriptors for all supported encodings
```

## Optional stdlib monkey-patch

Requiring `encoding/patch` routes stdlib string conversion and IO text
operations through the encoding shard, including builds with `-Dwithout_iconv`.
Raw IO reads and writes remain byte operations. The stdlib signatures retain
their options: `invalid: nil` raises on conversion errors, and `invalid: :skip`
discards them.

BOMs are preserved on decoding. Encoding names and mappings follow this shard's
WHATWG rules; the broader iconv charset set is unavailable. Conversion failures
raise `ArgumentError` with this shard's error messages.

```crystal
require "encoding/patch"

String.new(Bytes[0x63, 0x61, 0x66, 0xe9], "windows-1252") # => "café"
"café".encode("windows-1252") # => Bytes[0x63, 0x61, 0x66, 0xe9]

io = IO::Memory.new(Bytes[0xe9, 0x0a])
io.set_encoding("windows-1252")
io.gets # => "é"
```

The patch also accepts `invalid: :replace`, using `�` (U+FFFD) when decoding and
`?` when encoding. Pass `replacement: "[bad]"` to `IO#set_encoding`,
`String.new`, or `String#encode` to customize replacement; use `""` to discard
errors (same as `invalid: :skip`). Replacement strings must be valid UTF-8 and
representable in the output encoding.

`String.from_utf16` and `String#to_utf16` retain their stdlib implementations.

## Supported encodings and aliases

All WHATWG labels are accepted, case-insensitively, with leading and trailing
ASCII whitespace ignored. Names returned by descriptors use WHATWG canonical
spelling. Aliases are deliberately WHATWG aliases: `ascii`, `latin1`, and
`iso-8859-1` mean Windows-1252; `iso-8859-9` means Windows-1254; `utf-16` and
`unicode` mean UTF-16LE. The extension label `utf-32` means UTF-32LE. Unknown
labels raise `UnknownEncodingError`.

The charset set includes:

- UTF-8
- UTF-16LE/BE
- UTF-32LE/BE (extension)
- IBM866
- the standard's ISO-8859 and Windows single-byte encodings
- KOI8-R/U
- Macintosh
- x-mac-cyrillic
- GBK
- gb18030
- Big5
- EUC-JP
- ISO-2022-JP
- Shift_JIS
- EUC-KR
- and x-user-defined

It doesn't include the broader iconv charset set or arbitrary IANA aliases.

The standard's `replacement` pseudo-encoding and its aliases decode the first
nonempty input to a single replacement and discard the rest. They have no
encoder: encoding raises `UnsupportedEncodingError`. Inspect `can_encode?` when
selecting an output charset programmatically.

Some legacy mappings are asymmetric by design; converting to bytes and back
need not recover the original text. This includes Japanese yen/overline aliases,
halfwidth katakana in ISO-2022-JP, selected GB18030 private-use mappings, and Big5
combinations. The library applies the standard's encoder-specific duplicate
mapping rules rather than assuming the decoding table is bijective.

## Errors and replacements

Both directions default to `errors: :replace`. Decoding uses U+FFFD (`�`);
encoding uses `?` for unrepresentable characters and malformed UTF-8 input.
Pass `replacement:` to choose another valid UTF-8 string, or `""` to discard
errors. An encoder replacement must itself be representable in the destination
charset; invalid replacements raise `ArgumentError` during construction.

```crystal
Encoding.decode(Bytes[0xff, 0x41], replacement: "[bad]") # => "[bad]A"
Encoding.encode("Hello 💩", "windows-1252", replacement: "!")
Encoding.decode(Bytes[0xc0], errors: :strict) # raises InvalidByteSequenceError
Encoding.encode("💩", "windows-1252", errors: :strict) # raises UndefinedConversionError
```

`InvalidByteSequenceError` and `UndefinedConversionError` inherit from
`ConversionError`, exposing `encoding` (canonical conversion charset) and
`offset` (zero-based absolute input byte position). Malformed-input offsets
identify the beginning of the malformed sequence. Encoder offsets refer to UTF-8
input bytes, not character indices. Decoder offsets include any consumed BOM.

All library exceptions inherit from `Encoding::Error` except invalid options,
which raise `ArgumentError`.

## BOM policy

Decoding defaults to `bom: :detect`: a leading UTF-8, UTF-16LE/BE, or UTF-32LE/BE BOM
selects that encoding, overriding the requested charset, and is consumed. Without
a BOM the requested charset is used. Detection buffers at most four initial
bytes and works across chunk boundaries. UTF-16LE detection may wait for more
input to distinguish its BOM from UTF-32LE.

- `bom: :strip` disables overrides and consumes only an initial BOM matching the
  requested Unicode charset. Legacy encodings decode all input bytes normally.
- `bom: :preserve` disables detection and stripping. With the matching Unicode
  encoding an input BOM becomes U+FEFF in the output string.

Only one initial BOM is consumed. Embedded or repeated BOMs remain text. Encoding
omits a BOM unless `bom: true` is passed; emission is supported only for UTF-8,
UTF-16, and UTF-32 and otherwise raises `ArgumentError`. Even empty output
receives a BOM when emission is requested.

These library defaults differ from the standard's JavaScript API: conformance
specs select the appropriate explicit BOM policy when comparing codec behavior.

## Incremental conversion

```crystal
decoder = Encoding::Decoder.new("utf-8")
decoder.feed(Bytes[0xe2, 0x82]) # => ""
decoder.feed(Bytes[0xac])       # => "€"
decoder.finish                  # => ""

encoder = Encoding::Encoder.new("iso-2022-jp")
part = encoder.feed("日本")
tail = encoder.finish # emits the final return-to-ASCII escape sequence
```

`Decoder#feed(Bytes)` returns a UTF-8 `String`. `Encoder#feed(String | Bytes)`
returns `Bytes`; UTF-8 byte chunks may end inside a character. Empty chunks are
allowed. Incomplete sequences remain buffered until more input arrives or
`finish` reports/replaces truncation. `Decoder#encoding` reflects BOM detection.

`feed(input, output : IO)` and `finish(output : IO)` append directly to an
existing output and return `Nil`. Decoder output is UTF-8. These overloads
may leave partial output if conversion or writing fails. The IO adapters batch
writes using a reusable buffer.

Call `finish` once at end of input. After finalization or a conversion failure,
`feed` and `finish` raise `StateError` until `reset` is called. `reset` starts a
new stream with the original options, requested charset, offsets, and BOM policy.
Descriptors can also construct converters using `charset.decoder(...)` and
`charset.encoder(...)`. Use a separate converter per concurrent stream.

<!--
## IO conversion

```crystal
File.open("input.sjis") do |file|
  decoded = Encoding::DecoderIO.new(file, "shift_jis")
  text = decoded.gets_to_end
end

File.open("output.gbk", "w") do |file|
  encoded = Encoding::EncoderIO.new(file, "gbk")
  encoded << "你好"
  encoded.finish
end
```

`DecoderIO` is read-only and exposes UTF-8 bytes, so arbitrary read sizes may split
a UTF-8 character. `EncoderIO` is write-only and accepts UTF-8 bytes, including
split characters. Both adapters process bounded chunks instead of buffering the
whole file. Output buffering also depends on the chosen replacement length.

`EncoderIO#flush` flushes the underlying IO without finalizing codec state.
`finish` finalizes and flushes once, and can be called repeatedly. Writes after
`finish` raise `StateError`. `close` calls `finish` if needed. Conversion or
underlying IO failures make an adapter unusable; create a new adapter to resume.
Closing `DecoderIO` does not consume unread input or check it for truncation.

Both adapters leave their underlying IO open by default. Pass
`close_underlying: true` to transfer ownership. Closing is idempotent; owned
output is closed even if encoder finalization fails. Like ordinary streaming IO,
a failure can occur after earlier output has already been written.
-->

## License

Project code is Apache-2.0; see [LICENSE](LICENSE). WHATWG data and algorithms
and WPT-derived fixtures retain their upstream licensing and attribution; see
[NOTICE](NOTICE) and the licenses under `licenses/`.

[WHATWG Encoding Standard]: https://encoding.spec.whatwg.org/
