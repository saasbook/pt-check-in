# frozen_string_literal: true

# Marks every request as HTTPS. Used in preview mode, where a proxy terminates
# TLS and forwards plain HTTP to the app: without this the Secure session
# cookie would never be written and nobody could sign in.
class AssumeSsl
  def initialize(app)
    @app = app
  end

  def call(env)
    env["HTTPS"] = "on"
    env["rack.url_scheme"] = "https"
    env["SERVER_PORT"] = "443"
    @app.call(env)
  end
end
