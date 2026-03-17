require "vcr"
require "webmock/minitest"

VCR.configure do |c|
  c.cassette_library_dir = File.expand_path("../cassettes", __dir__)
  c.hook_into           :webmock
  c.default_cassette_options = {
    record:                :none,      # never hit the real network in CI
    allow_playback_repeats: true       # allow same request multiple times in one test
  }

  # Sanitize sensitive data if cassettes are ever re-recorded
  c.filter_sensitive_data("<API_KEY>") { ENV["POLYMARKET_API_KEY"] }
end
