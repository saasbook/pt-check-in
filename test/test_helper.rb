# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["SESSION_SECRET"] = "test-secret-" + ("x" * 64)
ENV["ALLOWLIST_EMAILS"] = "proctor@example.edu, Second.Proctor@Example.edu"
ENV["ALLOWLIST_SOURCE"] = ""
ENV["ROSTER_SOURCE"] = File.expand_path("fixtures/roster.csv", __dir__)
ENV["GOOGLE_CLIENT_ID"] = "test-client-id"
ENV["GOOGLE_CLIENT_SECRET"] = "test-client-secret"
# The sandbox may export a preview host; tests run in plain (non-preview) mode.
ENV["PREVIEW_HOST"] = ""
ENV["AGENT_WEB_HOST"] = ""
ENV["APP_BASE_URL"] = ""

require "minitest/autorun"
require "rack/test"

require_relative "../app"

OmniAuth.config.test_mode = true
OmniAuth.config.logger = Logger.new(File::NULL)
