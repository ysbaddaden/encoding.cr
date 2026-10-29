require "./source_cache"

case ARGV.shift?
when "download"
  # Restore pinned WHATWG inputs into the cache and WPT inputs into vendor/wpt.
  SourceCache.new.download
when "update"
  # Explicitly update both upstream heads, or only the requested source/ref.
  SourceCache.new.update(SourceCache.parse_update_args(ARGV))
when "check"
  # Verify cached WHATWG inputs, vendored WPT inputs, and licenses offline.
  count = {"whatwg", "wpt"}.sum { |name| SourceCache.verify(name) }
  puts "Verified #{count} pinned source files"
else
  abort "Usage: crystal run tools/sources.cr -- <download|update|check>"
end
