# frozen_string_literal: true

require "set"
require_relative "csv_source"

# The list of staff email addresses allowed to sign in.
#
# Addresses come from two places, and a user is allowed if they appear in either:
#
# * +static+: a comma/whitespace separated string, typically from the
#   ALLOWLIST_EMAILS environment variable. Handy for bootstrapping.
# * +source+: a URL (for example a Google Sheet published as CSV) or a local
#   file path holding CSV data, read through CsvSource. If the CSV has a header
#   row containing a column whose name includes "email", only that column is
#   used; otherwise every cell that looks like an email address is used.
class Allowlist
  EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  attr_reader :csv_source

  def initialize(source: nil, static: nil, ttl: 300, logger: nil)
    @static = self.class.normalize(static.to_s.split(/[\s,;]+/))
    @csv_source = CsvSource.new(source: source, ttl: ttl, logger: logger)
    @cache_key = nil
    @fetched = Set.new
    @lock = Mutex.new
  end

  def source?
    @csv_source.source?
  end

  def last_error
    @csv_source.last_error
  end

  def expire!
    @csv_source.expire!
  end

  # True if +email+ is allowed to sign in.
  def allowed?(email)
    normalized = email.to_s.strip.downcase
    return false unless normalized.match?(EMAIL_RE)

    @static.include?(normalized) || emails.include?(normalized)
  end

  # All emails currently known, refreshing the source first if it is stale.
  def emails
    @static | fetched_emails
  end

  # Extracts a Set of normalized email addresses from parsed CSV rows.
  def self.extract(rows)
    return Set.new if rows.empty?

    header = rows.first.map { |cell| cell.to_s.strip.downcase }
    email_column = header.index { |name| name.include?("email") }
    cells = email_column ? rows.drop(1).map { |row| row[email_column] } : rows.flatten
    normalize(cells)
  end

  def self.parse_csv(text)
    extract(CSV.parse(text.to_s, liberal_parsing: true))
  end

  def self.normalize(values)
    values.map { |v| v.to_s.strip.downcase }.select { |v| v.match?(EMAIL_RE) }.to_set
  end

  private

  # Emails from the CSV source, re-extracted only when the source was re-fetched.
  def fetched_emails
    rows = @csv_source.rows
    @lock.synchronize do
      key = @csv_source.fetched_at
      if key != @cache_key
        @fetched = self.class.extract(rows)
        @cache_key = key
      end
      @fetched
    end
  end
end
