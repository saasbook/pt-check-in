# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    App
  end

  def setup
    OmniAuth.config.mock_auth[:google] = nil
  end

  def mock_google(email:, name: "Pat Proctor")
    OmniAuth.config.mock_auth[:google] = OmniAuth::AuthHash.new(
      provider: "google", uid: "123",
      info: { email: email, name: name, image: "https://example.com/p.jpg" }
    )
  end

  # Loads the login page and returns the CSRF token embedded in its form.
  def login_page_token
    get "/login"
    assert last_response.ok?
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1].tap { |t| refute_nil t }
  end

  def sign_in(email)
    token = login_page_token
    post "/auth/google", authenticity_token: token
    assert last_response.redirect?, "expected redirect to Google callback, got #{last_response.status}"
    follow_redirect!
  end

  def test_root_redirects_to_login_when_signed_out
    get "/"
    assert last_response.redirect?
    assert_equal "/login", URI(last_response.location).path
  end

  def test_scan_requires_login
    get "/scan"
    assert last_response.redirect?
    assert_equal "/login", URI(last_response.location).path
  end

  def test_health
    get "/health"
    assert last_response.ok?
    assert_equal "ok", JSON.parse(last_response.body)["status"]
  end

  def test_login_page_has_google_form_with_csrf_token
    get "/login"
    assert last_response.ok?
    assert_includes last_response.body, 'action="/auth/google"'
    assert_match(/name="authenticity_token" value="\S+"/, last_response.body)
  end

  def test_login_post_without_csrf_token_is_rejected
    mock_google(email: "proctor@example.edu")
    get "/login"
    post "/auth/google"
    # OmniAuth refuses to start the flow and sends the user to the failure page.
    assert last_response.redirect?
    assert_equal "/auth/failure", URI(last_response.location).path
    assert_includes last_response.location, "message=Forbidden"
    get "/scan"
    assert last_response.redirect?, "no session should have been created"
  end

  def test_allowed_user_can_sign_in_and_scan
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    assert_equal "/scan", URI(last_response.location).path

    get "/scan"
    assert last_response.ok?
    assert_includes last_response.body, 'id="barcode-id"'
    assert_includes last_response.body, "/scanner.js"
    assert_includes last_response.body, "proctor@example.edu"
  end

  def test_allowlist_is_case_insensitive
    mock_google(email: "second.proctor@example.edu")
    sign_in("second.proctor@example.edu")
    assert_equal "/scan", URI(last_response.location).path
  end

  def test_user_not_on_allowlist_is_denied
    mock_google(email: "stranger@example.edu")
    sign_in("stranger@example.edu")
    assert_equal 403, last_response.status
    assert_includes last_response.body, "not on the allowed list"
    assert_includes last_response.body, "stranger@example.edu"

    get "/scan"
    assert last_response.redirect?, "denied user must not be signed in"
  end

  def test_unverified_email_is_denied
    mock_google(email: nil)
    sign_in(nil)
    assert_equal 403, last_response.status
    assert_includes last_response.body, "verified email"
  end

  def test_denied_page_escapes_html
    mock_google(email: "<script>alert(1)</script>@example.edu")
    sign_in(nil)
    refute_includes last_response.body, "<script>alert(1)"
  end

  def test_user_removed_from_allowlist_loses_access
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/scan"
    assert last_response.ok?

    original = App.settings.allowlist
    App.set :allowlist, Allowlist.new(static: "someone-else@example.edu")
    get "/scan"
    assert_equal 403, last_response.status
    assert_includes last_response.body, "not on the allowed list"
    get "/scan"
    assert last_response.redirect?, "session should have been cleared"
  ensure
    App.set :allowlist, original
  end

  def test_return_to_after_login
    get "/scan"
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    assert_equal "/scan", URI(last_response.location).path
  end

  def test_oauth_failure_shows_message
    mock_google(email: "proctor@example.edu")
    OmniAuth.config.mock_auth[:google] = :invalid_credentials
    token = login_page_token
    post "/auth/google", authenticity_token: token
    follow_redirect! # -> callback, which fails
    follow_redirect! # -> /auth/failure
    assert_equal 401, last_response.status
    assert_includes last_response.body, "Sign-in failed"
    assert_includes last_response.body, "invalid credentials"
  end

  def test_logout
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/scan"
    token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post "/logout", authenticity_token: token
    assert last_response.redirect?
    get "/scan"
    assert last_response.redirect?
  end

  def test_lookup_requires_login
    get "/api/lookup", code: "3034567890"
    assert_equal 401, last_response.status
    assert_equal "not signed in", JSON.parse(last_response.body)["error"]
  end

  def test_lookup_finds_student_and_strips_letters
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/api/lookup", code: "AB 3034567890"
    assert last_response.ok?, last_response.body
    body = JSON.parse(last_response.body)
    assert_equal "AB", body["letters"]
    assert_equal "3034567890", body["id"]
    assert body["roster"]["configured"]
    assert_nil body["roster"]["error"]
    assert_equal "Oski Bear", body["student"]["name"]
    assert_equal "oski@berkeley.edu", body["student"]["email"]
  end

  def test_lookup_unknown_student
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/api/lookup", code: "999"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert_nil body["student"]
    assert_equal "", body["letters"]
  end

  def test_lookup_without_roster_configured
    original = App.settings.roster
    App.set :roster, Roster.new(source: nil)
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/api/lookup", code: "3034567890"
    body = JSON.parse(last_response.body)
    refute body["roster"]["configured"]
    assert_equal "no roster configured", body["roster"]["error"]
    assert_nil body["student"]
  ensure
    App.set :roster, original
  end

  def test_lookup_rejects_missing_code
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/api/lookup"
    assert_equal 400, last_response.status
  end

  def test_frame_ancestors_allow_prairietest_and_no_x_frame_options
    get "/login"
    assert_nil last_response.headers["X-Frame-Options"]
    csp = last_response.headers["Content-Security-Policy"].to_s
    assert_includes csp, "frame-ancestors 'self' https://us.prairietest.com"
  end

  def test_scan_page_exposes_prairietest_settings
    mock_google(email: "proctor@example.edu")
    sign_in("proctor@example.edu")
    get "/scan"
    assert_includes last_response.body, 'data-pt-origin="https://us.prairietest.com"'
    assert_includes last_response.body, 'data-pt-id-field="uin"'
    assert_includes last_response.body, 'id="manual-id"'
  end

  def test_prairietest_harness_page_in_test_env
    get "/test-prairietest"
    assert last_response.ok?
    assert_includes last_response.body, 'src="/scan"'
    assert_includes last_response.body, '"init"'
  end

  def test_unknown_page_is_404
    get "/nope"
    assert_equal 404, last_response.status
  end
end
