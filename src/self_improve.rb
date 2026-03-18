require "faraday"
require "json"
require "dotenv/load"
require_relative "database"

ANTHROPIC_URL      = "https://api.anthropic.com"
PARAMS_FILE        = ENV.fetch("PARAMS_FILE",  "config/trade_params.json")
SCANNER_SRC        = ENV.fetch("SCANNER_SRC",  "src/market_scanner.rb")
WIN_RATE_THRESHOLD = (ENV["WIN_RATE_THRESHOLD"] || 0.55).to_f
CHECK_INTERVAL     = (ENV["SELF_IMPROVE_INTERVAL"] || 300).to_i   # seconds
RECENT_TRADE_LIMIT = 20

module SelfImprove
  class Orchestrator
    def run
      puts "[SelfImprove] Starting — checking every #{CHECK_INTERVAL}s (threshold: #{(WIN_RATE_THRESHOLD * 100).to_i}%)"
      loop do
        check_and_improve
        sleep CHECK_INTERVAL
      end
    end

    private

    # -------------------------------------------------------------------------
    # 1. Evaluate win rate
    # -------------------------------------------------------------------------
    def check_and_improve
      win_stats      = Database.win_rate
      accuracy_stats = Database.scan_accuracy

      if win_stats.nil?
        puts "[SelfImprove] No closed trades yet — skipping."
        if accuracy_stats
          puts "[SelfImprove] Claude scan accuracy so far: " \
               "#{(accuracy_stats[:accuracy] * 100).round(1)}% (#{accuracy_stats[:total]} resolved)"
        end
        return
      end

      puts "[SelfImprove] Win rate: #{(win_stats[:rate] * 100).round(1)}% (#{win_stats[:total]} closed trades)"
      puts "[SelfImprove] Claude scan accuracy: #{accuracy_stats ? "#{(accuracy_stats[:accuracy] * 100).round(1)}% (#{accuracy_stats[:total]} resolved)" : "n/a"}"

      return if win_stats[:rate] >= WIN_RATE_THRESHOLD

      warn "[SelfImprove] Below threshold! Dispatching Engineer Agent..."
      patch = call_engineer_agent(win_stats, accuracy_stats)
      return unless patch

      apply_patch(patch)
      restart_bot
    end

    # -------------------------------------------------------------------------
    # 2. Load trades from persistent storage
    # -------------------------------------------------------------------------

    # -------------------------------------------------------------------------
    # 3. Call Claude (Engineer Agent) to suggest parameter patch
    # -------------------------------------------------------------------------
    def call_engineer_agent(win_stats, accuracy_stats)
      code           = File.read(SCANNER_SRC)
      current_params = JSON.parse(File.read(PARAMS_FILE))
      recent_trades  = Database.recent_trades(limit: RECENT_TRADE_LIMIT)
      recent_scans   = Database.resolved_scans(limit: RECENT_TRADE_LIMIT)

      accuracy_line = accuracy_stats ?
        "Claude directional accuracy: #{(accuracy_stats[:accuracy] * 100).round(1)}% (#{accuracy_stats[:total]} resolved scans)" :
        "Claude directional accuracy: insufficient data"

      prompt = <<~PROMPT
        The Polymarket trading bot's win rate dropped to #{(win_stats[:rate] * 100).round(1)}%,
        below the #{(WIN_RATE_THRESHOLD * 100).to_i}% threshold.
        #{accuracy_line}

        ## Current trade parameters
        #{JSON.pretty_generate(current_params)}

        ## market_scanner.rb (source)
        ```ruby
        #{code}
        ```

        ## Last #{recent_trades.size} closed trades
        #{JSON.pretty_generate(recent_trades)}

        ## Last #{recent_scans.size} resolved scans (all signals including HOLDs)
        #{JSON.pretty_generate(recent_scans)}

        ## Task
        Analyse the losing trades and scan accuracy. Identify the root cause (bad edge
        filter, poor liquidity threshold, miscalibrated confidence, wrong scan interval,
        etc.) and propose adjusted parameters.

        Return ONLY valid JSON matching this schema exactly:
        {
          "min_edge":              0.XX,
          "max_position_usdc":     XXX,
          "min_liquidity":         XXXX,
          "scan_interval_seconds": XX,
          "reasoning":             "one paragraph"
        }
      PROMPT

      client = anthropic_client
      resp   = client.post(
        "/v1/messages",
        {
          model:      "claude-opus-4-6",
          max_tokens: 1024,
          system:     "You are an expert algorithmic trading engineer. Respond ONLY with valid JSON.",
          messages:   [{ role: "user", content: prompt }]
        },
        {
          "x-api-key"         => ENV.fetch("ANTHROPIC_API_KEY"),
          "anthropic-version" => "2023-06-01"
        }
      )

      body = JSON.parse(resp.body, symbolize_names: true)
      text = body[:content].first[:text]
      puts "[SelfImprove] Engineer Agent response:\n#{text}"

      JSON.parse(text, symbolize_names: true)
    rescue Faraday::Error => e
      warn "[SelfImprove] Anthropic API error: #{e.message}"
      nil
    rescue JSON::ParserError => e
      warn "[SelfImprove] Could not parse Engineer Agent response: #{e.message}"
      nil
    end

    # -------------------------------------------------------------------------
    # 4. Write the patched parameters to disk
    # -------------------------------------------------------------------------
    def apply_patch(patch)
      allowed_keys = %i[min_edge max_position_usdc min_liquidity scan_interval_seconds]
      new_params   = JSON.parse(File.read(PARAMS_FILE))

      allowed_keys.each do |key|
        new_params[key.to_s] = patch[key] if patch.key?(key)
      end

      new_params["updated_at"] = Time.now.utc.iso8601
      new_params["updated_by"] = "SelfImprove::EngineerAgent"

      File.write(PARAMS_FILE, JSON.pretty_generate(new_params))
      puts "[SelfImprove] Patch applied → #{PARAMS_FILE}"
      puts "[SelfImprove] Reasoning: #{patch[:reasoning]}"
    end

    # -------------------------------------------------------------------------
    # 5. Restart the scanner container so it picks up the new params
    # -------------------------------------------------------------------------
    def restart_bot
      puts "[SelfImprove] Parameters updated — restart market_scanner.rb to apply changes."
    end

    def anthropic_client
      Faraday.new(url: ANTHROPIC_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  SelfImprove::Orchestrator.new.run
end
