require "faraday"
require "json"

ANTHROPIC_API_URL  = "https://api.anthropic.com"
SYSTEM_PROMPT_PATH = ENV.fetch("SYSTEM_PROMPT_PATH", "/app/prompts/system_prompt.txt")

module Analyst
  class Client
    def initialize
      @http = Faraday.new(url: ANTHROPIC_API_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end
      @template = File.read(SYSTEM_PROMPT_PATH)
    end

    def analyze(market_question:, yes_price:, no_price:, btc_price:, delta:, news_summary: "N/A")
      system_prompt = build_system_prompt(
        market_question:, yes_price:, no_price:, btc_price:, delta:, news_summary:
      )

      resp = @http.post(
        "/v1/messages",
        {
          model:      "claude-opus-4-6",
          max_tokens: 512,
          system:     system_prompt,
          messages:   [{ role: "user", content: "Analyze this market." }]
        },
        {
          "x-api-key"         => ENV.fetch("ANTHROPIC_API_KEY"),
          "anthropic-version" => "2023-06-01"
        }
      )

      body = JSON.parse(resp.body, symbolize_names: true)
      JSON.parse(body[:content].first[:text], symbolize_names: true)
    rescue Faraday::Error => e
      warn "[Analyst] API error: #{e.message}"
      nil
    rescue JSON::ParserError => e
      warn "[Analyst] Could not parse Claude response: #{e.message}"
      nil
    end

    private

    def build_system_prompt(market_question:, yes_price:, no_price:, btc_price:, delta:, news_summary:)
      delta_str = delta ? "#{delta >= 0 ? '+' : ''}#{delta.round(2)}" : "N/A"

      @template
        .gsub("{market_question}", market_question.to_s)
        .gsub("{yes_price}",       yes_price.to_s)
        .gsub("{no_price}",        no_price.to_s)
        .gsub("{btc_price}",       btc_price.to_s)
        .gsub("{delta}",           delta_str)
        .gsub("{news_summary}",    news_summary.to_s)
    end
  end
end
