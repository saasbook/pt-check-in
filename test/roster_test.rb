# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class RosterTest < Minitest::Test
  def roster_with(csv)
    file = Tempfile.new(["roster", ".csv"])
    file.write(csv)
    file.flush
    @files = (@files || []) << file
    Roster.new(source: file.path)
  end

  def teardown
    (@files || []).each(&:close!)
  end

  def test_split_code
    assert_equal ["AB", "3034567890"], Roster.split_code("AB3034567890")
    assert_equal ["", "3034567890"], Roster.split_code(" 3034567890 ")
    assert_equal ["X", "12 34"], Roster.split_code("X 12 34")
    assert_equal ["", ""], Roster.split_code(nil)
    assert_equal ["ABC", ""], Roster.split_code("ABC")
  end

  def test_normalize_header
    assert_equal "student id", Roster.normalize_header("Student_ID")
    assert_equal "student id", Roster.normalize_header(" student-id ")
    assert_equal "email address", Roster.normalize_header("Email  Address")
  end

  def test_lookup_by_student_id_with_field_aliases
    roster = roster_with("Student_ID,Email Address,Full-Name,Notes\n3034567890,oski@berkeley.edu,Oski Bear,x\n")
    student = roster.lookup("3034567890")
    assert_equal "3034567890", student["sid"]
    assert_equal "Oski Bear", student["name"]
    assert_equal "oski@berkeley.edu", student["email"]
    refute student.key?("first_name")
    assert_nil roster.error
    assert_equal 1, roster.size
  end

  def test_lookup_by_sid_column_composes_name_from_first_and_last
    roster = roster_with("SID,email,first name,LAST-NAME\n12345,a@b.edu,Ada,Lovelace\n67890,,Only,\n")
    ada = roster.lookup("12345")
    assert_equal "Ada Lovelace", ada["name"]
    assert_equal "Ada", ada["first_name"]
    assert_equal "Lovelace", ada["last_name"]
    only = roster.lookup("67890")
    assert_equal "Only", only["name"]
    refute only.key?("email")
  end

  def test_lookup_strips_letter_prefix_and_whitespace_on_both_sides
    roster = roster_with("sid,name\nC 3034567890,Oski Bear\n")
    assert_equal "Oski Bear", roster.lookup("AB3034567890")["name"]
    assert_equal "Oski Bear", roster.lookup(" 3034567890 ")["name"]
    assert_nil roster.lookup("3034567891")
    assert_nil roster.lookup("")
    assert_nil roster.lookup("ABC")
  end

  def test_first_occurrence_wins_for_duplicate_ids
    roster = roster_with("sid,name\n1,First\n1,Second\n")
    assert_equal "First", roster.lookup("1")["name"]
  end

  def test_missing_id_column_reports_error
    roster = roster_with("Name,Email\nOski,oski@berkeley.edu\n")
    assert_nil roster.lookup("1")
    assert_match(/no "student id" or "sid" column/, roster.error)
    assert_match(/name, email/, roster.error)
  end

  def test_unconfigured_roster
    roster = Roster.new(source: "")
    refute roster.configured?
    assert_equal "no roster configured", roster.error
  end

  def test_unreadable_source_reports_error
    roster = Roster.new(source: "/nonexistent/roster.csv")
    assert roster.configured?
    assert_nil roster.lookup("1")
    assert_match(/ENOENT/, roster.error)
  end

  def test_changes_are_picked_up_after_expiry
    roster = roster_with("sid,name\n1,Before\n")
    assert_equal "Before", roster.lookup("1")["name"]
    File.write(roster.csv_source.source, "sid,name\n1,After\n")
    assert_equal "Before", roster.lookup("1")["name"], "cached within TTL"
    roster.expire!
    assert_equal "After", roster.lookup("1")["name"]
  end
end
