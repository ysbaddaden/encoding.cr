# Source maintenance is explicit; normal builds and specs never access the network.
require "json"
require "digest/sha256"
require "file_utils"
require "random/secure"
require "http/client"
require "openssl"

class SourceCache
  ROOT     = File.expand_path("..", __DIR__)
  PROJECTS = {
    "whatwg" => {repository: "whatwg/encoding", branch: "main", license: "LICENSE", notice: "licenses/WHATWG.txt"},
    "wpt"    => {repository: "web-platform-tests/wpt", branch: "master", license: "LICENSE.md", notice: "licenses/WPT.md"},
  }
  DOWNLOAD     = "crystal run tools/sources.cr -- download"
  UPDATE_USAGE = "Usage: crystal run tools/sources.cr -- update [--whatwg REF] [--wpt REF]"

  class Source
    include JSON::Serializable
    property repository : String
    property revision : String
    property files : Hash(String, String)

    def initialize(@repository, @revision, @files)
    end
  end

  class Lock
    include JSON::Serializable
    property version : Int32 = 1
    property sources : Hash(String, Source)

    def initialize(@sources)
    end
  end

  class HTTPError < Exception
    getter permanent : Bool

    def initialize(status : Int32, url : String)
      @permanent = status < 500 && status != 429
      super("HTTP #{status}: #{url}")
    end
  end

  @fetcher : Proc(String, HTTP::Client::Response)

  def initialize(@root : String = ROOT, fetcher : Proc(String, HTTP::Client::Response)? = nil, @log : IO = STDOUT)
    @fetcher = fetcher || ->SourceCache.http_get(String)
  end

  def self.http_get(url : String) : HTTP::Client::Response
    uri = URI.parse(url)
    client = HTTP::Client.new(uri)
    begin
      client.connect_timeout = 15.seconds
      client.read_timeout = 30.seconds
      client.write_timeout = 30.seconds
      client.get(uri.request_target, HTTP::Headers{"User-Agent" => "encoding.cr-source-tools"})
    ensure
      client.close
    end
  end

  def load_lock : Lock
    lock = Lock.from_json(File.read("#{@root}/sources.lock.json"))
    unless lock.version == 1 && lock.sources.keys.sort == PROJECTS.keys.sort
      raise "Unsupported sources.lock.json format"
    end
    lock.sources.each do |name, source|
      unless source.repository == PROJECTS[name][:repository] && revision?(source.revision)
        raise "Invalid repository/revision for #{name}"
      end
      raise "Missing #{name} license" unless source.files.has_key?(PROJECTS[name][:license])
      source.files.each do |file, hash|
        if file.includes?('\\') || file.split('/').any? { |part| {"", ".", ".."}.includes?(part) } || !hash.matches?(/\A[a-f0-9]{64}\z/)
          raise "Invalid source entry: #{name}/#{file}"
        end
      end
    end
    lock
  end

  def directory(name : String, revision : String) : String
    raise "Invalid source: #{name}" unless PROJECTS.has_key?(name) && revision?(revision)
    "#{@root}/.cache/sources/#{name}/#{revision}"
  end

  def directory(name : String) : String
    directory(name, load_lock.sources[name].revision)
  end

  # Offline entry points used by the mapping generator and source checker.
  def self.directory(name : String) : String
    new.directory(name)
  end

  def self.verify(name : String) : Int32
    new.verify([name])
  end

  def verify(names : Array(String) = PROJECTS.keys, lock : Lock = load_lock) : Int32
    count = 0
    names.each do |name|
      source = lock.sources[name]
      source.files.each do |file, expected|
        base = name == "wpt" ? "#{@root}/vendor/wpt" : directory(name, source.revision)
        path = "#{base}/#{file}"
        raise "Missing #{name}/#{file}; run #{DOWNLOAD}" unless File.file?(path)
        unless Digest::SHA256.hexdigest(File.read(path)) == expected
          raise "Checksum mismatch: #{name}/#{file}; run #{DOWNLOAD}"
        end
        count += 1
      end
      project = PROJECTS[name]
      notice = "#{@root}/#{project[:notice]}"
      unless File.file?(notice) && Digest::SHA256.hexdigest(File.read(notice)) == source.files[project[:license]]
        raise "License mismatch: #{project[:notice]}"
      end
    end
    count
  end

  def download : Nil
    lock = load_lock
    lock.sources.each do |name, source|
      if name == "wpt"
        begin
          verify([name], lock)
          next
        rescue
          # Restore missing or altered vendored inputs from the pinned source.
        end
      end
      @log.puts "#{name}: downloading/verifying #{source.revision}"
      fetch_source(name, source)
      vendor_wpt(source) if name == "wpt"
    end
    @log.puts "Verified #{verify(lock: lock)} pinned source files; sources.lock.json unchanged"
  end

  def self.parse_update_args(args : Array(String)) : Hash(String, String)
    return {"whatwg" => "latest", "wpt" => "latest"} if args.empty?
    refs = {} of String => String
    raise UPDATE_USAGE unless args.size.even?
    args.each_slice(2) do |pair|
      option, ref = pair
      name = option.lchop("--")
      unless option.starts_with?("--") && PROJECTS.has_key?(name) && !ref.empty? && !ref.starts_with?("--") && !refs.has_key?(name)
        raise UPDATE_USAGE
      end
      refs[name] = ref
    end
    refs
  end

  def update(refs : Hash(String, String)) : Nil
    # Loaded afresh, so a failed update never modifies tracked pins/notices.
    lock = load_lock
    refs.each do |name, ref|
      raise "Invalid source: #{name}" unless PROJECTS.has_key?(name) && !ref.empty?
      source = lock.sources[name]
      revision = ref
      unless revision?(revision)
        target = ref == "latest" ? PROJECTS[name][:branch] : ref
        url = "https://api.github.com/repos/#{source.repository}/commits/#{URI.encode_path_segment(target)}"
        revision = JSON.parse(request(url))["sha"]?.try(&.as_s?) || ""
        raise "Invalid upstream revision: #{name}" unless revision?(revision)
      end
      @log.puts "#{name}: #{source.revision} -> #{revision}"
      unchanged = source.revision == revision
      source.revision = revision
      source.files = fetch_source(name, source, unchanged)
    end
    lock.sources.each { |name, source| fetch_source(name, source) unless refs.has_key?(name) }
    # All downloads must succeed before publishing licenses or the lock.
    vendor_wpt(lock.sources["wpt"])
    lock.sources.each do |name, source|
      project = PROJECTS[name]
      license = File.read("#{directory(name, source.revision)}/#{project[:license]}")
      atomic_write("#{@root}/#{project[:notice]}", license)
    end
    atomic_write("#{@root}/sources.lock.json", lock.to_pretty_json + "\n")
    @log.puts "Pins and licenses updated. Regenerate tables/fixtures, run specs, and review the diff."
  end

  private def revision?(value : String) : Bool
    value.matches?(/\A[a-f0-9]{40}\z/)
  end

  private def vendor_wpt(source : Source) : Nil
    source.files.each_key do |file|
      atomic_write("#{@root}/vendor/wpt/#{file}", File.read("#{directory("wpt", source.revision)}/#{file}"))
    end
  end

  private def request(url : String) : String
    3.times do |attempt|
      begin
        response = @fetcher.call(url)
        raise HTTPError.new(response.status_code, url) unless (200..299).includes?(response.status_code)
        return response.body
      rescue ex
        raise ex if attempt == 2 || (ex.is_a?(HTTPError) && ex.permanent)
        sleep(250.milliseconds * (1 << attempt))
      end
    end
    raise "Unreachable"
  end

  private def atomic_write(path : String, bytes : String) : Nil
    FileUtils.mkdir_p(File.dirname(path))
    temporary = "#{path}.#{Random::Secure.hex(8)}.tmp"
    begin
      File.write(temporary, bytes)
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if File.exists?(temporary)
    end
  end

  private def fetch_file(name : String, source : Source, file : String, expected : Bool) : String
    path = "#{directory(name, source.revision)}/#{file}"
    bytes = File.file?(path) ? File.read(path) : nil
    if bytes.nil? || !expected || Digest::SHA256.hexdigest(bytes) != source.files[file]
      bytes = request("https://raw.githubusercontent.com/#{source.repository}/#{source.revision}/#{file}")
      if expected && Digest::SHA256.hexdigest(bytes) != source.files[file]
        raise "Checksum mismatch: #{name}/#{file}"
      end
      atomic_write(path, bytes)
    end
    Digest::SHA256.hexdigest(bytes)
  end

  private def fetch_source(name : String, source : Source, expected : Bool = true) : Hash(String, String)
    files = source.files.keys.sort
    results = Channel(Tuple(String, String) | Exception).new(files.size)
    slots = Channel(Nil).new(4)
    4.times { slots.send(nil) }
    files.each do |file|
      spawn do
        slots.receive
        begin
          results.send({file, fetch_file(name, source, file, expected)})
        rescue ex
          results.send(ex)
        ensure
          slots.send(nil)
        end
      end
    end
    hashes = {} of String => String
    failure : Exception? = nil
    files.size.times do
      case result = results.receive
      when Exception
        failure ||= result
      else
        hashes[result[0]] = result[1]
      end
    end
    raise failure if failure
    files.to_h { |file| {file, hashes[file]} }
  end
end
