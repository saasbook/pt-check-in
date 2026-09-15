# frozen_string_literal: true

require_relative "csv_source"

# Student roster used to look up a scanned ID.
#
# The roster is a CSV (typically a Google Sheet published as CSV) with a header
# row. Column names are matched case-insensitively, and spaces, hyphens and
# underscores in names are interchangeable, so "Student_ID", "student-id" and
# "Student ID" are all the same column.
#
# * The ID column is the first one named "student id" or "sid".
# * Displayed fields come from columns named "email" or "email address",
#   "name" or "full name", "first name", and "last name".
class Roster
  ID_COLUMNS = ["student id", "sid"].freeze
  FIELD_COLUMNS = {
    "name" => ["name", "full name"],
    "email" => ["email", "email address"],
    "first_name" => ["first name"],
    "last_name" => ["last name"],
  }.freeze

  attr_reader :csv_source

  def initialize(source: nil, ttl: 300, logger: nil)
    @csv_source = CsvSource.new(source: source, ttl: ttl, logger: logger)
    @logger = logger
    @cache_key = nil
    @index = {}
    @index_error = nil
    @lock = Mutex.new
  end

  def configured?
    @csv_source.source?
  end

  def expire!
    @csv_source.expire!
  end

  # A human-readable reason the roster cannot be used right now, or nil.
  def error
    return "no roster configured" unless configured?

    index # make sure the source has been read at least once
    return @index_error if @index_error
    return "#{@csv_source.last_error.class}: #{@csv_source.last_error.message}" if @csv_source.last_error && size.zero?

    nil
  end

  def size
    index.size
  end

  # Splits a scanned code into [letters, id]: every alphabetic character and
  # all whitespace are removed from the ID, e.g. "AB 3034567890" -> ["AB", "3034567890"].
  # Faculty and staff cards prefix the number with letters; some formats also
  # append them.
  def self.split_code(code)
    text = code.to_s.strip
    [text.scan(/[A-Za-z]+/).join, text.gsub(/[A-Za-z\s]+/, "")]
  end

  # Canonical form of an ID for matching: letters and whitespace removed.
  def self.normalize_id(value)
    split_code(value)[1]
  end

  def self.normalize_header(value)
    value.to_s.downcase.gsub(/[\s_-]+/, " ").strip
  end

  # Returns a Hash of student fields ("sid", "name", "email", "first_name",
  # "last_name"; only those present) or nil if the ID is not in the roster.
  def lookup(id)
    key = self.class.normalize_id(id)
    return nil if key.empty?

    index[key]
  end

  # Builds an index from parsed CSV rows: normalized ID => fields Hash.
  def self.build_index(rows)
    return [{}, nil] if rows.empty?

    header = rows.first.map { |cell| normalize_header(cell) }
    id_column = header.index { |name| ID_COLUMNS.include?(name) }
    return [{}, "roster has no \"student id\" or \"sid\" column (found: #{header.reject(&:empty?).join(", ")})"] unless id_column

    columns = FIELD_COLUMNS.transform_values do |aliases|
      header.index { |name| aliases.include?(name) }
    end

    index = {}
    rows.drop(1).each do |row|
      sid = normalize_id(row[id_column])
      next if sid.empty?

      fields = { "sid" => row[id_column].to_s.strip }
      columns.each do |field, column|
        value = column ? row[column].to_s.strip : ""
        fields[field] = value unless value.empty?
      end
      if !fields.key?("name") && (fields["first_name"] || fields["last_name"])
        fields["name"] = [fields["first_name"], fields["last_name"]].compact.join(" ")
      end
      index[sid] ||= fields # first occurrence wins
    end
    [index, nil]
  end

  private

  def index
    rows = @csv_source.rows
    @lock.synchronize do
      key = @csv_source.fetched_at
      if key != @cache_key
        @index, @index_error = self.class.build_index(rows)
        @cache_key = key
        @logger&.warn("Roster: #{@index_error}") if @index_error
      end
      @index
    end
  end
end
