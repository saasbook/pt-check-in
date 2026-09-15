# syntax=docker/dockerfile:1
FROM ruby:3.3-slim AS build

ENV BUNDLE_WITHOUT="development:test" \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
# Use the same Bundler version that produced Gemfile.lock.
RUN gem install bundler --no-document -v "$(tail -1 Gemfile.lock | tr -d ' ')" \
    && bundle install \
    && rm -rf "${BUNDLE_PATH}"/cache/*.gem


FROM ruby:3.3-slim

ENV RACK_ENV=production \
    PORT=8080 \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle

RUN useradd --create-home --shell /usr/sbin/nologin app
WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=app:app . .

USER app
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ruby -rnet/http -e 'exit(Net::HTTP.get_response(URI("http://127.0.0.1:#{ENV.fetch("PORT", 8080)}/health")).is_a?(Net::HTTPSuccess) ? 0 : 1)'

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
