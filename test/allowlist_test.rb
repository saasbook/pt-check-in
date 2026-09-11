# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"
require "webrick"

class AllowlistTest < Minitest::Test
  def test_parse_csv_uses_email_column_when_header_present
    csv = "Name,Email Address,Notes\nPat,Pat@Example.edu,likes coffee\nSam,sam@example.edu,\n,,\n"
    assert_equal Set["pat@example.edu", "sam@example.edu"], Allowlist.parse_csv(csv)
  end

  def test_parse_csv_without_header_takes_all_email_like_cells
    csv = "pat@example.edu\nsam@example.edu,extra\nnot an email\n"
    assert_equal Set["pat@example.edu", "sam@example.edu"], Allowlist.parse_csv(csv)
  end

  def test_parse_csv_ignores_non_emails_in_email_column
    csv = "email\nthis is a note\npat@example.edu\n"
    assert_equal Set["pat@example.edu"], Allowlist.parse_csv(csv)
  end

  def test_static_list_is_normalized
    list = Allowlist.new(static: "A@Example.edu, b@example.edu\nc@example.edu;junk")
    assert list.allowed?("a@example.edu")
    assert list.allowed?("  B@EXAMPLE.EDU ")
    assert list.allowed?("c@example.edu")
    refute list.allowed?("junk")
    refute list.allowed?("d@example.edu")
    refute list.allowed?("")
    refute list.allowed?(nil)
  end

  def test_file_source_is_read_and_cached
    Tempfile.create(["allow", ".csv"]) do |f|
      f.write("email\nfile@example.edu\n")
      f.flush
      list = Allowlist.new(source: f.path, ttl: 3600)
      assert list.allowed?("file@example.edu")
      refute list.allowed?("other@example.edu")

      # Within the TTL the file is not re-read.
      File.write(f.path, "email\nother@example.edu\n")
      assert list.allowed?("file@example.edu")
      refute list.allowed?("other@example.edu")

      # After the TTL expires the new content is picked up.
      list.expire!
      assert list.allowed?("other@example.edu")
      refute list.allowed?("file@example.edu")
    end
  end

  def test_failed_refresh_keeps_previous_list
    Tempfile.create(["allow", ".csv"]) do |f|
      f.write("email\nkeep@example.edu\n")
      f.flush
      list = Allowlist.new(source: f.path, ttl: 0)
      assert list.allowed?("keep@example.edu")
      File.delete(f.path)
      assert list.allowed?("keep@example.edu"), "old list should survive a failed refresh"
      assert_kind_of Errno::ENOENT, list.last_error
      File.write(f.path, "") # so Tempfile.create can clean up
    end
  end

  def test_static_and_source_are_combined
    Tempfile.create(["allow", ".csv"]) do |f|
      f.write("src@example.edu\n")
      f.flush
      list = Allowlist.new(source: f.path, static: "static@example.edu")
      assert list.allowed?("src@example.edu")
      assert list.allowed?("static@example.edu")
    end
  end

  def test_http_source_follows_redirects
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1",
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    port = server.config[:Port]
    server.mount_proc("/redirect") { |_req, res| res.set_redirect(WEBrick::HTTPStatus::Found, "http://127.0.0.1:#{port}/list.csv") }
    server.mount_proc("/list.csv") { |_req, res| res.body = "email\nweb@example.edu\n" }
    server.mount_proc("/broken") { |_req, res| res.status = 500 }
    thread = Thread.new { server.start }

    list = Allowlist.new(source: "http://127.0.0.1:#{port}/redirect")
    assert list.allowed?("web@example.edu")
    refute list.allowed?("nobody@example.edu")

    broken = Allowlist.new(source: "http://127.0.0.1:#{port}/broken", static: "static@example.edu")
    refute broken.allowed?("web@example.edu")
    assert broken.allowed?("static@example.edu"), "static list still works when the source is down"
    assert_match(/HTTP 500/, broken.last_error.message)
  ensure
    server&.shutdown
    thread&.join(5)
  end
end
