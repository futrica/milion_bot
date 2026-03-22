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

    # series: array of { time:, up_price:, btc_price:, delta_5m:, spread:, liquidity: }
    # prev_windows: array of { question:, accuracy:, correct:, total: }
    # recent_performance: { total:, wins:, losses:, win_rate: } or nil
    def analyze_series(market_question:, series:, prev_windows: [], recent_performance: nil)
      table      = build_table(series)
      indicators = compute_indicators(series)

      prompt = @template
        .gsub("{market_question}",    market_question.to_s)
        .gsub("{series_table}",       table)
        .gsub("{indicators}",         format_indicators(indicators))
        .gsub("{prev_windows}",       format_prev_windows(prev_windows))
        .gsub("{recent_performance}", format_performance(recent_performance))

      call_api(prompt)
    end

    private

    # -------------------------------------------------------------------------
    # Table
    # -------------------------------------------------------------------------
    def build_table(series)
      header = "time      | up_price | btc_price   | delta_5m    | delta_1m    | volume_5m  | spread | liquidity"
      sep    = "-" * header.length
      rows   = series.map do |s|
        d5m_s    = s[:delta_5m]  ? format("%+.4f%%", s[:delta_5m])  : "N/A"
        d1m_s    = s[:delta_1m]  ? format("%+.4f%%", s[:delta_1m])  : "N/A"
        vol_s    = s[:volume_5m] ? format("%.2f",    s[:volume_5m]) : "N/A"
        spread_s = s[:spread]    ? format("%.4f",    s[:spread])    : "N/A"
        liq_s    = s[:liquidity] ? format("$%.0f",   s[:liquidity]) : "N/A"
        "#{s[:time]}  | #{s[:up_price].to_s.ljust(8)} | $#{s[:btc_price].to_s.ljust(10)} | #{d5m_s.ljust(11)} | #{d1m_s.ljust(11)} | #{vol_s.ljust(10)} | #{spread_s} | #{liq_s}"
      end
      ([header, sep] + rows).join("\n")
    end

    # -------------------------------------------------------------------------
    # Technical indicators
    # -------------------------------------------------------------------------
    def compute_indicators(series)
      up_prices  = series.map { |s| s[:up_price].to_f  }.reject(&:zero?)
      btc_prices = series.map { |s| s[:btc_price].to_f }.reject(&:zero?)
      deltas_5m  = series.map { |s| s[:delta_5m].to_f  }.compact
      deltas_1m  = series.map { |s| s[:delta_1m].to_f  }.compact
      volumes    = series.map { |s| s[:volume_5m].to_f }.reject(&:zero?)
      spreads    = series.map { |s| s[:spread].to_f    }.reject(&:zero?)
      liq        = series.map { |s| s[:liquidity].to_f }.reject(&:zero?)

      {
        rsi_up:        compute_rsi(up_prices),
        btc_trend:     compute_slope(btc_prices),
        up_trend:      compute_slope(up_prices),
        avg_delta_5m:  deltas_5m.empty? ? nil : (deltas_5m.sum / deltas_5m.size).round(4),
        avg_delta_1m:  deltas_1m.empty? ? nil : (deltas_1m.sum / deltas_1m.size).round(4),
        delta_accel:   compute_acceleration(deltas_5m),
        latest_volume: volumes.last&.round(2),
        avg_volume:    volumes.empty? ? nil : (volumes.sum / volumes.size).round(2),
        latest_spread: spreads.last&.round(4),
        avg_liquidity: liq.empty? ? nil : (liq.sum / liq.size).round(0)
      }
    end

    def compute_rsi(prices, period = 7)
      return nil if prices.size < period + 1

      changes  = prices.each_cons(2).map { |a, b| b - a }
      gains    = changes.map { |c| [c,  0].max }
      losses   = changes.map { |c| [-c, 0].max }
      avg_gain = gains.last(period).sum  / period.to_f
      avg_loss = losses.last(period).sum / period.to_f

      return 100.0 if avg_loss.zero?

      rs = avg_gain / avg_loss
      (100.0 - (100.0 / (1 + rs))).round(1)
    end

    def compute_slope(values)
      n = values.size
      return nil if n < 2

      x_mean = (n - 1) / 2.0
      y_mean = values.sum / n.to_f
      num    = values.each_with_index.sum { |y, x| (x - x_mean) * (y - y_mean) }
      den    = values.each_with_index.sum { |_, x| (x - x_mean)**2 }
      den.zero? ? 0.0 : (num / den).round(6)
    end

    def compute_acceleration(deltas)
      return nil if deltas.size < 4

      mid         = deltas.size / 2
      first_half  = deltas.first(mid).sum / mid.to_f
      second_half = deltas.last(mid).sum  / mid.to_f
      (second_half - first_half).round(4)
    end

    def format_indicators(ind)
      [
        "RSI(7) on UP price : #{ind[:rsi_up]      || "N/A"} (>70 overbought, <30 oversold)",
        "BTC price slope    : #{ind[:btc_trend]    || "N/A"} (per tick, positive=rising)",
        "UP price slope     : #{ind[:up_trend]     || "N/A"} (per tick, positive=market buying UP)",
        "Avg delta_5m       : #{ind[:avg_delta_5m] ? format("%+.4f%%", ind[:avg_delta_5m]) : "N/A"}",
        "Avg delta_1m       : #{ind[:avg_delta_1m] ? format("%+.4f%%", ind[:avg_delta_1m]) : "N/A"} (short-term momentum)",
        "Delta acceleration : #{ind[:delta_accel]  ? format("%+.4f%%", ind[:delta_accel])  : "N/A"} (positive=momentum building)",
        "Latest volume_5m   : #{ind[:latest_volume] || "N/A"} BTC (vs avg #{ind[:avg_volume] || "N/A"}) — high vol confirms trend",
        "Latest bid-ask spread : #{ind[:latest_spread] || "N/A"} (>0.05 = thin book, lower confidence)",
        "Avg orderbook liq  : $#{ind[:avg_liquidity] || "N/A"}"
      ].join("\n")
    end

    def format_prev_windows(windows)
      return "No previous windows available." if windows.empty?

      windows.map do |w|
        acc = w[:total].to_i > 0 ? "#{(w[:accuracy].to_f * 100).round(0)}% Claude accuracy (#{w[:correct]}/#{w[:total]} scans)" : "unresolved"
        "- #{w[:question]}: #{acc}"
      end.join("\n")
    end

    def format_performance(perf)
      return "No resolved live trades yet." if perf.nil? || perf[:total].to_i.zero?

      "Last #{perf[:total]} live trades: #{perf[:wins]}W / #{perf[:losses]}L — " \
      "#{(perf[:rate].to_f * 100).round(1)}% win rate"
    end

    # -------------------------------------------------------------------------
    # API call
    # -------------------------------------------------------------------------
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
