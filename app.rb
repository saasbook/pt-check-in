# frozen_string_literal: true

require "dotenv"
Dotenv.load # reads .env for local development; never overrides real env vars

require "json"
require "logger"
require "securerandom"
require "sinatra/base"
require "omniauth"
require "omniauth-google-oauth2"

require_relative "lib/allowlist"
require_relative "lib/roster"
require_relative "lib/assume_ssl"

# Proctor check-in app: staff sign in with Google, then scan student ID barcodes.
class App < Sinatra::Base
  set :root, __dir__
  set :erb, escape_html: true
  enable :logging

  configure do
    secret = ENV["SESSION_SECRET"].to_s
    if secret.empty?
      raise "SESSION_SECRET must be set (generate one with: ruby -rsecurerandom -e 'puts SecureRandom.hex(64)')" if production?

      secret = SecureRandom.hex(64) # development/test only; sessions reset on restart
    elsif secret.bytesize < 64
      raise "SESSION_SECRET must be at least 64 characters long"
    end

    # Sign-in provider. Without Google credentials (local development, live
    # previews) fall back to OmniAuth's developer strategy: a plain form that
    # asks for an email address. Never in production.
    google_client_id = ENV["GOOGLE_CLIENT_ID"].to_s.strip
    if production? && google_client_id.empty?
      raise "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET must be set in production"
    end
    set :dev_login, google_client_id.empty?
    set :auth_provider, settings.dev_login ? "developer" : "google"

    # Who may sign in. In development with no allowlist configured at all, let
    # anyone in so the app is usable out of the box.
    allowlist_configured = !ENV["ALLOWLIST_SOURCE"].to_s.strip.empty? || !ENV["ALLOWLIST_EMAILS"].to_s.strip.empty?
    raise "ALLOWLIST_SOURCE or ALLOWLIST_EMAILS must be set in production" if production? && !allowlist_configured
    set :allow_anyone, !allowlist_configured
    set :allowlist, Allowlist.new(
      source: ENV["ALLOWLIST_SOURCE"],
      static: ENV["ALLOWLIST_EMAILS"],
      ttl: Integer(ENV.fetch("ALLOWLIST_TTL_SECONDS", 300)),
      logger: Logger.new($stderr)
    )

    set :roster, Roster.new(
      source: ENV["ROSTER_SOURCE"],
      ttl: Integer(ENV.fetch("ROSTER_TTL_SECONDS", 300)),
      logger: Logger.new($stderr)
    )

    # Live preview support: when the app is embedded in an iframe on another
    # origin (for example a Superconductor preview, which provides
    # AGENT_WEB_HOST), allow framing by that UI and let the session cookie be
    # sent cross-site.
    preview_host = ENV["PREVIEW_HOST"].to_s.strip
    preview_host = ENV["AGENT_WEB_HOST"].to_s.strip if preview_host.empty?
    set :preview_host, preview_host.empty? ? nil : preview_host
    set :frame_ancestors, ENV.fetch("PREVIEW_FRAME_ANCESTORS", "https://superconductor.com https://*.superconductor.com")
    if settings.preview_host && development?
      # Sinatra only answers to local hostnames in development.
      set :host_authorization, { permitted_hosts: settings.host_authorization[:permitted_hosts] + [settings.preview_host] }
    end

    set :sessions,
        key: "pt_check_in.session",
        secret: secret,
        expire_after: 12 * 60 * 60,
        same_site: settings.preview_host ? :none : :lax,
        httponly: true,
        secure: production? || !settings.preview_host.nil?,
        coder: Rack::Session::Cookie::Base64::JSON.new

    # Sinatra's default protections plus a per-session CSRF token, which is
    # what OmniAuth 2 expects on the POST that starts the login flow.
    protection = { use: :authenticity_token }
    if settings.preview_host
      protection[:except] = [:frame_options] # replaced by a CSP frame-ancestors header below
      protection[:permitted_origins] = ["https://#{settings.preview_host}"]
    end
    set :protection, protection

    OmniAuth.config.allowed_request_methods = [:post]
    OmniAuth.config.failure_raise_out_environments = [] # always redirect to /auth/failure
    OmniAuth.config.logger = Logger.new($stderr)
    base_url = ENV["APP_BASE_URL"].to_s.strip
    base_url = "https://#{settings.preview_host}" if base_url.empty? && settings.preview_host
    OmniAuth.config.full_host = base_url.sub(%r{/+\z}, "") unless base_url.empty?

    unless test?
      warn "pt-check-in: GOOGLE_CLIENT_ID not set; using the development sign-in form" if settings.dev_login
      warn "pt-check-in: no allowlist configured; anyone can sign in" if settings.allow_anyone
      warn "pt-check-in: preview mode for https://#{settings.preview_host}" if settings.preview_host
    end
  end

  use OmniAuth::Builder do
    if App.settings.dev_login
      provider :developer, fields: [:name, :email], uid_field: :email
    else
      options = {
        name: "google",
        scope: "email,profile",
        prompt: "select_account",
        access_type: "online",
      }
      hosted_domain = ENV["GOOGLE_HOSTED_DOMAIN"].to_s.strip
      options[:hd] = hosted_domain unless hosted_domain.empty?
      provider :google_oauth2, ENV["GOOGLE_CLIENT_ID"], ENV["GOOGLE_CLIENT_SECRET"], options
    end
  end

  before do
    if settings.preview_host
      headers["Content-Security-Policy"] = "frame-ancestors 'self' #{settings.frame_ancestors}"
    end
  end

  # The app as mounted in config.ru. In preview mode the TLS-terminating proxy
  # sends plain HTTP, so requests are marked as HTTPS before the session
  # middleware sees them; otherwise the Secure session cookie is never set.
  def self.rack_app
    app = self
    Rack::Builder.new do
      use AssumeSsl if app.settings.preview_host
      run app
    end
  end

  helpers do
    def current_user
      session["user"]
    end

    def logged_in?
      !current_user.nil?
    end

    # Ensures the request comes from a signed-in, still-allowed user.
    #
    # Anonymous users are redirected to the login page (or get a 401 for JSON
    # endpoints). Signed-in users are re-checked against the allowlist so that
    # removing someone from the list takes effect within ALLOWLIST_TTL_SECONDS,
    # not at the end of their session.
    def authorize!(json: false)
      unless logged_in?
        halt 401, { "Content-Type" => "application/json" }, { error: "not signed in" }.to_json if json

        session["return_to"] = request.path_info
        redirect "/login"
      end

      email = current_user["email"]
      return if allowed?(email)

      logger.warn("Session ended for #{email}: no longer on the allowlist")
      session.clear
      halt 403, { "Content-Type" => "application/json" }, { error: "not allowed" }.to_json if json
      halt 403, erb(:denied, locals: { email: email })
    end

    def require_login!
      authorize!
    end

    def allowed?(email)
      settings.allow_anyone || settings.allowlist.allowed?(email)
    end

    def csrf_token
      Rack::Protection::AuthenticityToken.token(session)
    end

    def page_title(title = nil)
      title ? "#{title} - PrairieTest Check-in" : "PrairieTest Check-in"
    end
  end

  get "/" do
    redirect(logged_in? ? "/scan" : "/login")
  end

  get "/login" do
    redirect "/scan" if logged_in?

    erb :login, locals: { error: nil }
  end

  # OmniAuth handles POST /auth/google (or the development form) and lands here
  # once the user has been authenticated.
  auth_callback = lambda do
    halt 404 unless params["provider"] == settings.auth_provider

    auth = request.env["omniauth.auth"]
    # omniauth-google-oauth2 only fills info.email when Google reports the
    # address as verified.
    email = auth&.dig("info", "email").to_s.strip.downcase
    if email.empty? || !email.match?(Allowlist::EMAIL_RE)
      session.clear
      status 403
      return erb :denied, locals: { email: nil }
    end

    unless allowed?(email)
      logger.warn("Sign-in denied for #{email}: not on the allowlist")
      session.clear
      status 403
      return erb :denied, locals: { email: email }
    end

    return_to = session["return_to"]
    session.clear
    session["user"] = {
      "email" => email,
      "name" => auth.dig("info", "name").to_s,
      "picture" => auth.dig("info", "image").to_s,
    }
    logger.info("Signed in #{email}")
    redirect(return_to.to_s.start_with?("/") ? return_to : "/scan")
  end
  get "/auth/:provider/callback", &auth_callback
  post "/auth/:provider/callback", &auth_callback

  get "/auth/failure" do
    reason = params["message"].to_s.tr("_", " ")
    status 401
    erb :login, locals: { error: "Sign-in failed#{reason.empty? ? "" : " (#{reason})"}. Please try again." }
  end

  post "/logout" do
    session.clear
    redirect "/login"
  end

  get "/scan" do
    require_login!
    erb :scan
  end

  # Looks up a scanned code in the roster. The leading letters of the code are
  # treated as a prefix and stripped before the lookup.
  get "/api/lookup" do
    authorize!(json: true)
    content_type :json
    code = params["code"].to_s.strip
    halt 400, { error: "missing code" }.to_json if code.empty?
    halt 400, { error: "code too long" }.to_json if code.length > 100

    prefix, id = Roster.split_code(code)
    roster = settings.roster
    student = roster.configured? ? roster.lookup(id) : nil
    {
      raw: code,
      prefix: prefix,
      id: id,
      roster: { configured: roster.configured?, error: roster.error },
      student: student,
    }.to_json
  end

  get "/health" do
    content_type :json
    { status: "ok" }.to_json
  end

  not_found do
    erb :not_found
  end
end
