# CONTRIBUTING

## Development and conformance

Normal builds require only Crystal. Specs are offline; generate their local WPT
fixtures first with Node.js 24:

```sh
node tools/import_wpt.js
crystal spec
crystal tool format --check src spec tools bench
```

Generated mapping tables, pinned WPT sources in `vendor/wpt/`, source pins,
licenses, and coverage documentation are checked in. WPT fixtures are generated
into `.cache/wpt/`, which is ignored by Git; regenerate them after changing the
vendored sources or importer. Node.js is needed only for fixture generation.
WHATWG mapping inputs are downloaded into the ignored
`.cache/sources/whatwg/<commit>/` directory. Source downloading, pin updates,
verification, and mapping generation use Crystal.

### Download the pinned inputs

```sh
crystal run tools/sources.cr -- download
crystal run tools/sources.cr -- check
crystal run tools/generate.cr -- --check
node tools/import_wpt.js
node tools/import_wpt.js --check
```

The download command restores exactly the revisions and SHA-256 checksums in
[sources.lock.json](sources.lock.json), without modifying the pins or licenses.
It verifies vendored WPT inputs and restores missing or corrupted files; valid
vendored inputs require no download. WHATWG inputs use the ignored source cache.
Verification, mapping generation, and WPT fixture generation are offline. CI
explicitly downloads mapping inputs in the generated-data verification job.

To regenerate mapping tables and local fixtures:

```sh
crystal run tools/generate.cr
node tools/import_wpt.js
```

### Update source pins

```sh
# Resolve both upstream default branches and pin their current commits.
crystal run tools/sources.cr -- update

# Alternatively, update only one source to a branch, tag, or full commit SHA.
crystal run tools/sources.cr -- update --whatwg main
crystal run tools/sources.cr -- update --wpt FULL_COMMIT_SHA
```

Updating downloads all required inputs at the selected immutable commits,
records their checksums in `sources.lock.json`, refreshes `vendor/wpt/`, and updates the retained
upstream license files. Unselected sources keep their existing pins. Download
failures leave the pins and retained licenses unchanged. Mapping tables and local fixtures are
generated separately:

```sh
crystal run tools/generate.cr
node tools/import_wpt.js
crystal spec
crystal run tools/sources.cr -- check
crystal run tools/generate.cr -- --check
node tools/import_wpt.js --check
```

Review and commit the lock, generated mapping tables, vendored sources, and any
license changes together. Generated fixtures and their coverage manifest remain
in the ignored local cache. Adding a new generator dependency requires adding its upstream path to
the lock's file inventory; updating pins fetches that inventory at the new
revision. Tests never implicitly download sources or update pins.

See [spec/WPT.md](spec/WPT.md) for the conformance baseline, exclusions, and
adaptation details. Additional Crystal specs cover incremental boundaries,
malformed sequences, custom replacement, BOM overrides, aliases, error offsets,
lifecycle, and IO behavior.

## Benchmarks

Run the benchmark in release mode. Results are printed to the terminal; no result
files are written:

```sh
crystal run --release bench/encoding.cr
```

By default it measures encoding and decoding for every encodable WHATWG charset,
using ASCII and charset-specific mixed text at UTF-8 payload lengths of 0, 16,
256, 4096, and 65536 bytes. Empty inputs are measured once per charset/direction.
Each case has 0.1 seconds of warmup and 0.5 seconds of measurement, so the full
matrix takes several minutes. To select a smaller matrix or measure longer:

```sh
crystal run --release bench/encoding.cr -- \
  --encodings utf-8,windows-1252,gb18030,iso-2022-jp \
  --sizes 16,4096,65536 --warmup 0.5 --time 2
```

Other filters are `--direction encode|decode|both` and
`--profile ascii|mixed|both`. Pass `--chunk-size 31` to measure incremental
encoding/decoding instead of the one-shot helpers. Chunk boundaries may split
UTF-8 characters, external multibyte sequences, and stateful escape sequences.
Use `--help` to list options.

Inputs and decoder byte buffers are prepared and strictly round-trip checked
before timing. Each measured operation constructs a fresh converter and includes
finalization, using the library's default error and BOM policies. Incremental
runs consume each returned chunk without concatenating the output. These are
valid-input conversion benchmarks; malformed-input recovery and IO adapters are
not measured.

The standard Crystal benchmark report includes operations/second, variation,
and allocated bytes/operation. Row labels identify direction, charset, profile,
UTF-8 payload byte length (`utf8`), and actual input byte length (`in`). Decoder
input lengths can differ from the UTF-8 payload size. Higher operations/second
and lower allocated bytes/operation are better for the same row. The report's
within-run "fastest" ratios compare different workloads, not revisions.

To compare commits or tags, rebuild and run the same benchmark version with
identical options, compiler version, and machine conditions at each revision.
Repeat runs to distinguish consistent changes from measurement noise; use longer
`--warmup` and `--time` values for closer comparisons. Process startup and table
initialization are outside the timed region.

