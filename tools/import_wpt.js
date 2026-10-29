// Development-only extraction. Uses pinned WPT expected values/reference codecs,
// never Node's TextDecoder, iconv, or the implementation under test.
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const root = path.resolve(__dirname, '..');
const crypto = require('node:crypto');

function main() {
  const lock = JSON.parse(fs.readFileSync(path.join(root, 'sources.lock.json'), 'utf8'));
  const pinned = lock.sources.wpt;
  if (lock.version !== 1 || pinned.repository !== 'web-platform-tests/wpt' ||
      !/^[a-f0-9]{40}$/.test(pinned.revision)) throw new Error('Invalid WPT source pin');
  const cache = path.join(root, 'vendor/wpt');
  for (const [file, expected] of Object.entries(pinned.files)) {
    if (file.includes('\\') || file.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error(`Invalid WPT source path: ${file}`);
    }
    const target = path.join(cache, file);
    if (!fs.existsSync(target)) throw new Error('Missing vendored WPT inputs; run crystal run tools/sources.cr -- download');
    const digest = crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex');
    if (digest !== expected) throw new Error(`Checksum mismatch: wpt/${file}`);
  }
  const license = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'licenses/WPT.md'))).digest('hex');
  if (license !== pinned.files['LICENSE.md']) throw new Error('License mismatch: licenses/WPT.md');
  const wpt = path.join(cache, 'encoding');
  const fixtures = [];
  const coverage = [];
  let source, title;
  let last;
  class Result {
    constructor(decoder, calls, unit = null) { Object.assign(this, {decoder, calls, unit}); }
    charCodeAt(unit) { return new Result(this.decoder, this.calls, unit); }
  }
  class Decoder {
    constructor(encoding = 'utf-8', options = {}) {
      this.label = encoding;
      this.fatal = !!options.fatal;
      this.ignoreBOM = !!options.ignoreBOM;
      this.calls = [];
    }
    decode(input = new Uint8Array(), options = {}) {
      const bytes = Array.from(ArrayBuffer.isView(input)
        ? new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
        : new Uint8Array(input));
      this.calls.push({bytes, stream: !!options.stream});
      last = new Result(this, this.calls.slice());
      if (!options.stream) this.calls = [];
      return last;
    }
  }
  function record(actual, expected, error = false) {
    if (!(actual instanceof Result)) return; // WebIDL attributes have no codec output.
    fixtures.push({source, test: title, encoding: actual.decoder.label,
      strict: actual.decoder.fatal, bom: actual.decoder.ignoreBOM ? 'preserve' : 'strip',
      calls: actual.calls, unit: actual.unit, expected: error ? null : expected, error});
  }
  function extract(file, dependencies = []) {
    source = file;
    const start = fixtures.length;
    const context = vm.createContext({
      TextDecoder: Decoder, ArrayBuffer, DataView, Uint8Array, Int8Array,
      test(fn, name) { title = name; fn(); },
      assert_equals(actual, expected) { record(actual, expected); },
      assert_not_equals(actual, expected) { record(actual, expected); fixtures[fixtures.length - 1].not = true; },
      assert_true() {}, assert_false() {},
      assert_throws_js(type, fn) { last = null; fn(); if (last) record(last, null, true); },
      TypeError,
    });
    for (const dep of dependencies) vm.runInContext(fs.readFileSync(path.join(wpt, dep), 'utf8'), context);
    vm.runInContext(fs.readFileSync(path.join(wpt, file), 'utf8'), context, {filename: file});
    coverage.push({source: file, kind: 'assertions', cases: fixtures.length - start});
  }
  extract('legacy-mb-schinese/gb18030/gb18030-decoder.any.js', ['legacy-mb-schinese/gb18030/resources/ranges.js']);
  extract('legacy-mb-schinese/gbk/gbk-decoder.any.js');
  extract('iso-2022-jp-decoder.any.js');
  extract('textdecoder-eof.any.js');
  extract('textdecoder-fatal.any.js');
  extract('textdecoder-utf16-surrogates.any.js');
  extract('textdecoder-byte-order-marks.any.js');
  extract('textdecoder-ignorebom.any.js');

  // HTML encoder tests expose direct encode(input, expectedQuery, description)
  // calls. Unescape URL bytes; HTML's numeric-reference fallback is tested as a
  // strict conversion failure because it is not this library's replacement policy.
  for (const [file, encoding] of [
    ['big5-encoder.html', 'big5'], ['iso-2022-jp-encoder.html', 'iso-2022-jp'],
    ['legacy-mb-schinese/gb18030/gb18030-encoder.html', 'gb18030'],
    ['legacy-mb-schinese/gbk/gbk-encoder.html', 'gbk'],
  ]) {
    source = file;
    const start = fixtures.length;
    let text = fs.readFileSync(path.join(wpt, file), 'utf8');
    let script = [...text.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join('\n');
    // Replace only the harness helper definition; preserve all upstream vectors
    // and generated range-boundary cases.
    if (script.includes('const encode =')) {
      script = script.replace(/const encode = [\s\S]*?\n };?/, '');
    } else {
      script = script.replace(/function encode\([\s\S]*?\n }/, '');
    }
    const context = vm.createContext({
      encode(input, query, desc) {
        const bytes = Array.from(Buffer.from(query.replace(/%([0-9A-Fa-f]{2})/g,
          (_, hex) => String.fromCharCode(parseInt(hex, 16))), 'latin1'));
        fixtures.push({source, test: desc || 'range', encoding, direction: 'encode', input,
          bytes, error: /%26%23\d+%3B/i.test(query)});
      },
    });
    if (encoding === 'gb18030') vm.runInContext(fs.readFileSync(path.join(wpt, 'legacy-mb-schinese/gb18030/resources/ranges.js'), 'utf8'), context);
    vm.runInContext(script, context, {filename: file});
    coverage.push({source: file, kind: 'encoder vectors', cases: fixtures.length - start});
  }

  // WPT reference decoders independently exercise every two-byte combination,
  // plus JIS0212 three-byte entries and ISO-2022-JP double-byte entries. Store
  // compact rows rather than hundreds of thousands of duplicated JSON objects.
  const references = [];
  for (const [encoding, directory, files, fn] of [
    ['euc-jp', 'legacy-mb-japanese/euc-jp', ['jis0208_index.js', 'jis0212_index.js', 'eucjp-decoder.js'], 'eucjpDecoder'],
    ['shift_jis', 'legacy-mb-japanese/shift_jis', ['jis0208_index.js', 'sjis-decoder.js'], 'sjisDecoder'],
    ['iso-2022-jp', 'legacy-mb-japanese/iso-2022-jp', ['jis0208_index.js', 'iso2022jp-decoder.js'], 'iso2022jpDecoder'],
    ['euc-kr', 'legacy-mb-korean/euc-kr', ['euckr_index.js', 'euckr-decoder.js'], 'euckrDecoder'],
    ['big5', 'legacy-mb-tchinese/big5', ['big5_index.js', 'big5-decoder.js'], 'big5Decoder'],
  ]) {
    const context = vm.createContext({});
    for (const file of files) vm.runInContext(fs.readFileSync(path.join(wpt, directory, file), 'utf8'), context);
    const rows = [];
    function add(bytes) {
      const stream = bytes.map(x => x.toString(16).padStart(2, '0')).join(' ');
      rows.push([bytes, context[fn](stream)]);
    }
    if (encoding === 'iso-2022-jp') {
      for (let a = 0x21; a <= 0x7e; a++) for (let b = 0; b < 256; b++) add([0x1b, 0x24, 0x42, a, b]);
    } else {
      for (let a = 0; a < 256; a++) for (let b = 0; b < 256; b++) add([a, b]);
      if (encoding === 'euc-jp') for (let a = 0xa1; a <= 0xfe; a++) for (let b = 0; b < 256; b++) add([0x8f, a, b]);
    }
    references.push({encoding, rows});
    coverage.push({source: directory, kind: 'exhaustive WPT reference decoder', cases: rows.length});
  }
  // Exercise every mapped code point through WPT's independent reference encoders.
  const encoderReferences = [];
  for (const [encoding, directory, files, fn, indexes] of [
    ['euc-jp', 'legacy-mb-japanese/euc-jp', ['jis0208_index.js', 'eucjp-encoder.js'], 'eucjpEncoder', ['jis0208']],
    ['shift_jis', 'legacy-mb-japanese/shift_jis', ['jis0208_index.js', 'sjis-encoder.js'], 'sjisEncoder', ['jis0208']],
    ['iso-2022-jp', 'legacy-mb-japanese/iso-2022-jp', ['jis0208_index.js', 'iso2022jp-encoder.js'], 'iso2022jpEncoder', ['jis0208', 'iso2022jpkatakana']],
    ['euc-kr', 'legacy-mb-korean/euc-kr', ['euckr_index.js', 'euckr-encoder.js'], 'euckrEncoder', ['euckr']],
    ['big5', 'legacy-mb-tchinese/big5', ['big5_index.js', 'big5-encoder.js'], 'big5Encoder', ['big5']],
  ]) {
    const context = vm.createContext({alert(message) { throw new Error(message); }});
    for (const file of files) vm.runInContext(fs.readFileSync(path.join(wpt, directory, file), 'utf8'), context);
    const cps = new Set(Array.from({length: 256}, (_, i) => i));
    for (const index of indexes) for (const cp of context[index]) if (cp !== null) cps.add(cp);
    for (let cp = 0xff61; cp <= 0xff9f; cp++) cps.add(cp);
    for (const cp of [0xa5, 0x203e, 0x2212, 0x1f4a9, 0xfffd, 0x10ffff]) cps.add(cp);
    const rows = [];
    for (const cp of [...cps].sort((a, b) => a - b)) {
      const encoded = context[fn](String.fromCodePoint(cp));
      rows.push([cp, encoded === null ? null : encoded.split(/\s+/).filter(Boolean).map(x => parseInt(x, 16))]);
    }
    encoderReferences.push({encoding, rows});
    coverage.push({source: directory, kind: 'WPT reference encoder mapped code points', cases: rows.length});
  }
  const single = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(wpt, 'resources/encodings.js'), 'utf8'), single);
  // Only load WPT's table declarations; the following browser harness is not used.
  const singleSource = fs.readFileSync(path.join(wpt, 'resources/single-byte-decoder.js'), 'utf8');
  vm.runInContext(singleSource.slice(0, singleSource.indexOf('\nfunction ')), single);
  const singleIndexes = vm.runInContext('singleByteIndexes', single);
  const labels = vm.runInContext('encodings_table', single);
  const outputs = {
    '.cache/wpt/wpt.json': JSON.stringify(fixtures) + '\n',
    '.cache/wpt/wpt-encoders.json': JSON.stringify(encoderReferences) + '\n',
    '.cache/wpt/wpt-reference.json': JSON.stringify(references) + '\n',
    '.cache/wpt/wpt-single-byte.json': JSON.stringify(singleIndexes) + '\n',
    '.cache/wpt/wpt-labels.json': JSON.stringify(labels) + '\n',
    '.cache/wpt/wpt-coverage.json': JSON.stringify(coverage, null, 2) + '\n',
  };
  fs.mkdirSync(path.join(root, '.cache/wpt'), {recursive: true});
  for (const [file, data] of Object.entries(outputs)) {
    const target = path.join(root, file);
    if (process.argv.includes('--check')) {
      if (fs.readFileSync(target, 'utf8') !== data) throw new Error('Stale fixture: ' + file);
    } else fs.writeFileSync(target, data);
  }
  console.log(`${fixtures.length} assertions; ${references.reduce((n, x) => n + x.rows.length, 0)} reference cases`);
}
try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
