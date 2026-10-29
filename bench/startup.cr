# Run after building two revisions of bench/optimizations.cr with --release:
# crystal run bench/startup.cr -- /tmp/before /tmp/after
# Each subprocess exits immediately after library initialization.
paths = ARGV
raise ArgumentError.new("Expected before and after executable paths") unless paths.size == 2

def launch(path : String) : Nil
  status = Process.run(path, args: ["startup"], output: Process::Redirect::Close, error: STDERR)
  raise "Startup failed: #{path}" unless status.success?
end

paths.each { |path| 5.times { launch(path) } }
samples = [Array(Float64).new, Array(Float64).new]
100.times do |iteration|
  # Alternate order to reduce systematic effects from machine drift.
  order = iteration.even? ? {0, 1} : {1, 0}
  order.each do |i|
    started = Time.instant
    launch(paths[i])
    samples[i] << (Time.instant - started).total_milliseconds
  end
end

medians = samples.map do |values|
  sorted = values.sort
  (sorted[49] + sorted[50]) / 2
end
paths.each_with_index do |path, i|
  puts "#{path}: median #{medians[i].round(3)} ms (100 launches)"
end
puts "Speedup: #{(medians[0] / medians[1]).round(2)}x"
