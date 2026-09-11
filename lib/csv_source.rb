# frozen_string_literal: true

require "csv"
require "net/http"
require "uri"

# Fetches and caches CSV rows from a URL (for example a Google Sheet published
# as CSV) or a local file path.
#
# The source is re-read at most once every +ttl+ seconds, on demand. If a
# refresh fails the previously loaded rows are kept and +last_error+ is set, so
# a transient outage does not break the app.
class CsvSource
  MAX_REDIRECTS = 5
  FETCH_TIMEOUT = 10 # seconds

  attr_reader :source, :ttl, :fetched_at, :last_error

  def initialize(source: nil, ttl: 300, logger: nil)
    @source = source.to_s.strip.empty? ? nil : source.to_s.strip
    @ttl = ttl
    @logger = logger
    @rows = []
    @fetched_at = nil
    @last_error = nil
    @lock = Mutex.new
  end

  def source?
    !@source.nil?
  end

  # Parsed CSV rows (arrays of strings), refreshing first if stale.
  def rows
    refresh_if_stale!
    @lock.synchronize { @rows }
  end

  def stale?
    source? && (@fetched_at.nil? || Time.now - @fetched_at > @ttl)
  end

  # Forces the next access to re-read the source.
  def expire!
    @lock.synchronize { @fetched_at = nil }
  end

  def refresh_if_stale!
    refresh! if stale?
  end

  # Re-reads the source. Returns true on success. On failure the old rows are
  # kept, +last_error+ is set, and false is returned.
  def refresh!
    return false unless source?

    parsed = CSV.parse(read_source(@source), liberal_parsing: true)
    @lock.synchronize do
      @rows = parsed
      @fetched_at = Time.now
      @last_error = nil
    end
    log(:info, "Loaded #{parsed.size} row(s) from #{@source}")
    true
  rescue StandardError => e
    @lock.synchronize do
      # Back off before retrying so a broken source is not hammered on every request.
      @fetched_at = Time.now
      @last_error = e
    end
    log(:warn, "Refresh from #{@source} failed: #{e.class}: #{e.message}")
    false
  end

  private

  def read_source(source)
    if source.match?(%r{\Ahttps?://}i)
      fetch_url(URI(source))
    else
      File.read(source)
    end
  end

  def fetch_url(uri, redirects_left = MAX_REDIRECTS)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
      http.get(uri.request_uri, "User-Agent" => "pt-check-in")
    end

    case response
    when Net::HTTPSuccess
      response.body.to_s.dup.force_encoding("UTF-8")
    when Net::HTTPRedirection
      raise "too many redirects" if redirects_left.zero?

      fetch_url(URI.join(uri, response["location"]), redirects_left - 1)
    else
      raise "HTTP #{response.code} from #{uri.host}"
    end
  end

  def log(level, message)
    @logger&.public_send(level, message)
  end
end
