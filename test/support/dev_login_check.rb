# frozen_string_literal: true

# Loads the app with the current ENV and checks the development sign-in flow.
# Run by test/dev_login_test.rb; exits non-zero on failure.
require "bundler/setup"
require "rack/test"
require "json"

mode = ENV.fetch("MODE")

def check(condition, message)
  return if condition

  warn "FAILED: #{message}"
  exit 1
end

if mode == "production"
  require_relative "../../app"
  include Rack::Test::Methods
  def app = App.rack_app
  header "Host", "checkin.example.edu"
  env "HTTPS", "on"
  get "/test-prairietest"
  check(last_response.status == 404, "harness page must be hidden in production, got #{last_response.status}")
  get "/login"
  check(last_response.ok?, "login page should render in production, got #{last_response.status}")
  cookie = last_response.headers["Set-Cookie"].to_s.downcase
  check(cookie.include?("samesite=none") && cookie.include?("secure"), "production cookie must be SameSite=None; Secure for PrairieTest's iframe, got #{cookie.inspect}")
  check(last_response.headers["X-Frame-Options"].nil?, "no X-Frame-Options in production")
  check(last_response.headers["Content-Security-Policy"].to_s.include?("https://us.prairietest.com"), "CSP must allow PrairieTest")
  puts "dev login check (production) passed"
  exit 0
end

if mode == "production_boot_fails"
  begin
    require_relative "../../app"
    check(false, "production boot should fail without Google credentials")
  rescue RuntimeError => e
    check(e.message.include?("GOOGLE_CLIENT_ID"), "unexpected error: #{e.message}")
  end
  exit 0
end

require_relative "../../app"
include Rack::Test::Methods
def app = App.rack_app

# Sinatra only permits local hostnames in development; talk to it as the
# preview host when one is configured, otherwise as localhost.
header "Host", App.settings.preview_host || "localhost"

check(App.settings.dev_login, "dev_login should be enabled without GOOGLE_CLIENT_ID")
check(App.settings.auth_provider == "developer", "provider should be developer")

get "/login"
check(last_response.ok?, "login page should render, got #{last_response.status}: #{last_response.body[0, 500]}")
check(last_response.body.include?('action="/auth/developer/callback"'), "login page should show the development form")
check(!last_response.body.include?("/auth/google"), "login page should not offer Google")
token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]

get "/auth/google/callback"
check(last_response.status == 404, "google callback should be disabled in dev-login mode")

case mode
when "allow_anyone"
  check(App.settings.allow_anyone, "allow_anyone should be on without an allowlist")
  post "/auth/developer/callback", authenticity_token: token, name: "Dev", email: "anyone@example.edu"
  check(last_response.redirect? && URI(last_response.location).path == "/scan", "developer sign-in should redirect to /scan, got #{last_response.status} #{last_response.body[0, 200]}")
  get "/scan"
  check(last_response.ok? && last_response.body.include?("anyone@example.edu"), "scan page should show the signed-in email")
  post "/auth/developer/callback", authenticity_token: token, name: "Dev", email: "not-an-email"
  check(last_response.status == 403, "garbage email should be rejected")
when "allowlist"
  check(!App.settings.allow_anyone, "allow_anyone should be off when ALLOWLIST_EMAILS is set")
  post "/auth/developer/callback", authenticity_token: token, name: "Dev", email: "stranger@example.edu"
  check(last_response.status == 403 && last_response.body.include?("not on the allowed list"), "stranger should be denied")
  check(last_response.body.include?('href="/login"'), "denied page should link back to login in dev mode")
  get "/login"
  token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  post "/auth/developer/callback", authenticity_token: token, name: "Dev", email: "Proctor@Example.edu"
  check(last_response.redirect? && URI(last_response.location).path == "/scan", "allowlisted email should sign in")
when "harness_hidden_in_production"
  # Not reachable: production requires Google and an allowlist; see below.
when "preview"
  check(App.settings.preview_host == "preview.example.com", "preview host should come from AGENT_WEB_HOST")
  check(OmniAuth.config.full_host == "https://preview.example.com", "OmniAuth full_host should use the preview host")
  get "/login"
  check(last_response.headers["X-Frame-Options"].nil?, "X-Frame-Options must not be sent in preview mode")
  csp = last_response.headers["Content-Security-Policy"].to_s
  check(csp.include?("frame-ancestors") && csp.include?("superconductor.com"), "CSP frame-ancestors should allow the preview UI, got #{csp.inspect}")
  cookie = last_response.headers["Set-Cookie"].to_s
  check(cookie.downcase.include?("samesite=none") && cookie.downcase.include?("secure"), "session cookie should be SameSite=None; Secure, got #{cookie.inspect}")
  # A cross-origin POST from the preview host must be accepted.
  header "Origin", "https://preview.example.com"
  post "/auth/developer/callback", authenticity_token: token, name: "Dev", email: "anyone@example.edu"
  check(last_response.redirect? && URI(last_response.location).path == "/scan", "sign-in from the preview origin should work, got #{last_response.status}")
else
  check(false, "unknown MODE #{mode}")
end

puts "dev login check (#{mode}) passed"
