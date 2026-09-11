# frozen_string_literal: true

# Puma configuration. Values can be overridden with environment variables.
environment ENV.fetch("RACK_ENV", "development")
bind "tcp://0.0.0.0:#{ENV.fetch("PORT", 8080)}"

max_threads = Integer(ENV.fetch("PUMA_MAX_THREADS", 5))
threads Integer(ENV.fetch("PUMA_MIN_THREADS", max_threads)), max_threads

# Single process mode keeps the in-memory allowlist cache shared and is plenty
# for a handful of proctors.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))
preload_app! if Integer(ENV.fetch("WEB_CONCURRENCY", 0)) > 0
