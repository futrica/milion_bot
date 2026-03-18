require "faraday"
require "json"

ANTHROPIC_API_URL  = "https://api.anthropic.com"
SYSTEM_PROMPT_PATH = ENV.fetch("SYSTEM_PROMPT_PATH", "prompts/system_prompt.txt")

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

    # series: array of { time:, up_price:, btc_price:, delta_5m: }
    def analyze_series(market_question:, series:)
      table = build_table(series)
      prompt = @template
        .gsub("{market_question}", market_question.to_s)
        .gsub("{series_table}",    table)

      call_api(prompt)
    end

    private

    def build_table(series)
      header = "time      | up_price | btc_price   | delta_5m"
      sep    = "-" * header.length
      rows   = series.map do |s|
        delta_s = s[:delta_5m] ? format("%+.4f%%", s[:delta_5m]) : "N/A"
        "#{s[:time]}  | #{s[:up_price].to_s.ljust(8)} | $#{s[:btc_price].to_s.ljust(10)} | #{delta_s}"
      end
      ([header, sep] + rows).join("\n")
    end

    def call_api(system_prompt)
      resp = @http.post(
        "/v1/messages",
        {
          model:      "claude-haiku-4-5-20251001",
          max_tokens: 512,
          system:     system_prompt,
          messages:   [{ role: "user", content: "Analyze the series and give your recommendation." }]
        },
        {
          "x-api-key"         => ENV.fetch("ANTHROPIC_API_KEY"),
          "anthropic-version" => "2023-06-01"
        }
      )

      body = JSON.parse(resp.body, symbolize_names: true)
      text = body[:content].first[:text].gsub(/\A```json\s*|\s*```\z/, "").strip
      JSON.parse(text, symbolize_names: true)
    rescue Faraday::Error => e
      warn "[Analyst] API error: #{e.message}"
      nil
    rescue JSON::ParserError => e
      warn "[Analyst] Could not parse Claude response: #{e.message}"
      nil
    end
  end
end
