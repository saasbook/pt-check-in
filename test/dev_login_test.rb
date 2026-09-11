# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The sign-in provider and allowlist mode are fixed when app.rb loads, so the
# development configuration is exercised in a subprocess with its own ENV.
class DevLoginTest < Minitest::Test
  SCRIPT = File.expand_path("support/dev_login_check.rb", __dir__)

  def run_check(env)
    base = {
      "RACK_ENV" => "development", "SESSION_SECRET" => "x" * 64,
      "GOOGLE_CLIENT_ID" => "", "GOOGLE_CLIENT_SECRET" => "",
      "ALLOWLIST_SOURCE" => "", "ALLOWLIST_EMAILS" => "", "ROSTER_SOURCE" => "",
      "APP_BASE_URL" => "", "PREVIEW_HOST" => "", "AGENT_WEB_HOST" => "",
    }
    out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, SCRIPT, chdir: File.expand_path("..", __dir__))
    assert status.success?, "dev login check failed:\n#{out}\n#{err}"
    out
  end

  def test_development_login_without_google_allows_anyone
    run_check("MODE" => "allow_anyone")
  end

  def test_development_login_respects_allowlist_when_configured
    run_check("MODE" => "allowlist", "ALLOWLIST_EMAILS" => "proctor@example.edu")
  end

  def test_preview_mode_headers_and_cookies
    run_check("MODE" => "preview", "AGENT_WEB_HOST" => "preview.example.com")
  end

  def test_production_requires_google_and_allowlist
    run_check("MODE" => "production_boot_fails", "RACK_ENV" => "production")
  end
end
