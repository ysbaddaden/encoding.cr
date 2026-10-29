# WPT conformance baseline

The input files used by the adaptation are pinned by revision and SHA-256 in
`../sources.lock.json` and checked in byte-for-byte under `../vendor/wpt/`.
Run `node tools/import_wpt.js` with Node.js 24 before `crystal spec` to generate
fixtures offline into the ignored `../.cache/wpt/` directory. Specs read these
local fixtures; they do not need a browser or network access. Regenerate after
changing the vendored sources or importer. Fixtures are not checked into Git.

`../.cache/wpt/wpt-coverage.json` lists the upstream files/reference families that
produce fixtures and their case counts. `../tools/import_wpt.js` is the executable
adaptation: it uses upstream expected values and upstream reference codecs,
without using Node's native `TextDecoder` or this library to derive answers.

## Executed baseline

- Explicit GB18030/GBK decoder vectors, GB18030 range boundaries, and GB18030-2022
  compatibility cases.
- ISO-2022-JP decoder vectors, including invalid/truncated escapes, forbidden
  controls, repeated state transitions, and chunked state reset behavior.
- UTF-8 end-of-queue and strict decoding assertions; UTF-16 malformed surrogate
  cases; matching, mismatched, and ignored BOM assertions.
- Big5, ISO-2022-JP, GBK, and GB18030 HTML encoder vectors, including duplicate
  mapping selection, excluded pointers, range boundaries, and unmappable input.
- All 65,536 two-byte inputs for each WPT reference decoder for EUC-JP,
  Shift_JIS, EUC-KR, and Big5; all JIS0212 lead/trail combinations for EUC-JP;
  every JIS0208 leading byte followed by every possible byte for ISO-2022-JP.
  Each case also runs with one-byte chunks separated by empty chunks.
- WPT reference encoder results for every code point in their corresponding
  indexes, with ASCII, halfwidth katakana, special aliases, and unmappable probes.
- Every single-byte mapping and undefined entry from WPT's single-byte table,
  in replacement and strict mode; encoding of every defined character.
- Every alias from WPT's encoding table, with ASCII case and whitespace variants.

## Adaptation rules and exclusions

Only the inputs used by the adaptation are downloaded; the original browser
suite is not claimed to run in full.
There are no pending or silently skipped examples in the Crystal specs.

- WebIDL, JavaScript argument coercion, prototype/attribute shapes, realm checks,
  ArrayBuffer/SharedArrayBuffer ownership and transfer, DOM document loading,
  response headers, navigation, form submission, and URL query escaping are
  browser integration behavior, outside the Crystal conversion API.
- The HTML encoder assertions are adapted to raw output bytes by unescaping
  percent escapes. HTML numeric-character-reference fallback is adapted to a
  strict unmappable-character assertion; the library's replacement policy is
  tested separately. Literal standard encoder output is preserved unchanged.
- Browser Streams promises, backpressure, cancellation, and cross-realm behavior
  are outside scope. Stateful codec behavior is tested through incremental
  converters, exhaustive byte-by-byte replay, and Crystal IO adapter specs.
- JavaScript lone UTF-16 surrogate *strings* have no direct Crystal scalar-string
  equivalent. Malformed UTF-8 `String`/`Bytes` input and malformed external UTF-16
  byte input are tested explicitly instead.
- Browser `TextDecoder` implicitly starts a new stream after a final decode.
  Extracted fixtures retain the calls within each logical stream; Crystal specs
  use fresh converters or explicit `reset`. This library requires explicit reset
  after both completion and failure.
- Browser API rejection of replacement encodings is not imposed on the native
  library: their specified pseudo-decoder is supported and separately tested.
- Default BOM overrides and configurable substitutions are library policies.
  Imported WPT decoder assertions use `:strip` or `:preserve`, matching the
  source assertion's `ignoreBOM` option. Separate specs exercise `:detect`.
- Repeated aliases/HTML character datasets are represented by the independent
  WPT mapping/reference-codec sweeps and alias matrix rather than loading their
  iframes. The file-level codec vectors explicitly imported are enumerated in
  `../.cache/wpt/wpt-coverage.json`; new applicable regressions should be added to the importer
  or translated into a Crystal regression spec with the upstream source named.

Reproduce fixtures offline with `node tools/import_wpt.js`; append `--check`
to verify they have not changed. This also verifies `../.cache/wpt/wpt-coverage.json` case counts.
