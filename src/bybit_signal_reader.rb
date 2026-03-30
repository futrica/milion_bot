require "sqlite3"
require "time"

module BybitSignalReader
  BYBIT_DB = "/Users/futrica/projects/bybit_bot/data/bot.db"
  MAX_AGE  = 300  # seconds — signal older than 5min is ignored

  # Returns hash { probability:, edge:, recommendation:, confidence:, reasoning: }
  # compatible with Analyst::Client output.
  # Returns nil if signal unavailable, too old, or flat.
  def self.analyze(up_price)
    signal = latest_signal
    return nil unless signal

    direction  = signal["direction"].to_s.to_sym   # :long, :short, :flat
    confidence = signal["confidence"].to_f

    return nil if direction == :flat || confidence.zero?

    # Trend boost: align confidence with Medium/Macro trend context
    boost      = trend_boost(signal["reasoning"], direction)
    confidence = (confidence + boost).round(2)
    warn "[BybitSignal] Trend boost +#{boost.round(2)} → conf=#{confidence}" if boost > 0

    # Determine signal source tag for prospective backtest analysis
    raw_reasoning = signal["reasoning"].to_s
    source = if raw_reasoning.start_with?("trend-only:")
      "trend_only"
    elsif raw_reasoning.start_with?("open position fallback")
      "open_trade"
    elsif boost > 0
      "boosted+#{boost.round(2)}"
    else
      "active"
    end

    # Implied probability from technical signal
    bybit_prob = direction == :long ? confidence : (1.0 - confidence)

    # Alignment filter: only enter when bybit and Polymarket agree on direction.
    # bybit LONG + yes_price > 0.50 → both bullish → BUY_YES
    # bybit SHORT + yes_price < 0.50 → both bearish → BUY_NO
    # If they disagree → skip (contrarian bets from bybit have no edge)
    bybit_bullish  = bybit_prob > 0.5
    market_bullish = up_price.to_f > 0.5
    unless bybit_bullish == market_bullish
      warn "[BybitSignal] Skipping: direction mismatch (bybit=#{direction} conf=#{confidence.round(2)}, market yes=#{up_price})"
      return nil
    end

    edge = (bybit_prob - up_price.to_f).round(4)
    rec  = bybit_bullish ? "BUY_YES" : "BUY_NO"

    {
      probability:    bybit_prob.round(4),
      edge:           edge,
      recommendation: rec,
      confidence:     confidence,
      reasoning:      "[source:#{source}] #{raw_reasoning}"
    }
  rescue => e
    warn "[BybitSignal] Error: #{e.message}"
    nil
  end

  def self.latest_signal
    db = SQLite3::Database.new(BYBIT_DB, readonly: true)
    db.results_as_hash = true
    row = db.execute(
      "SELECT direction, confidence, reasoning, timestamp FROM signals
       WHERE dry_run = 0
       ORDER BY id DESC LIMIT 1"
    ).first
    db.close

    if row && row["direction"].to_s != "flat" && row["confidence"].to_f > 0
      age = Time.now.to_i - Time.parse(row["timestamp"]).to_i
      return row if age <= MAX_AGE
      warn "[BybitSignal] Signal stale (#{age}s) — checking open trades"
    end

    open_trade_signal || trend_only_signal
  rescue => e
    warn "[BybitSignal] DB read failed: #{e.message}"
    nil
  end

  def self.parse_trend(reasoning)
    medium = reasoning&.[](/Medium=(bull|bear|neutral)/i, 1)&.downcase&.to_sym || :neutral
    macro  = reasoning&.[](/Macro=(bull|bear|neutral)/i, 1)&.downcase&.to_sym  || :neutral
    { medium: medium, macro: macro }
  end

  def self.trend_boost(reasoning, direction)
    trend = parse_trend(reasoning)
    boost = 0.0
    boost += 0.05 if (direction == :long  && trend[:medium] == :bull) ||
                     (direction == :short && trend[:medium] == :bear)
    boost += 0.05 if (direction == :long  && trend[:macro]  == :bull) ||
                     (direction == :short && trend[:macro]  == :bear)
    boost
  end

  def self.trend_only_signal
    db = SQLite3::Database.new(BYBIT_DB, readonly: true)
    db.results_as_hash = true
    row = db.execute(
      "SELECT reasoning, timestamp FROM signals WHERE dry_run=0 ORDER BY id DESC LIMIT 1"
    ).first
    db.close
    return nil unless row

    age = Time.now.to_i - Time.parse(row["timestamp"]).to_i
    return nil if age > MAX_AGE

    trend = parse_trend(row["reasoning"])
    if trend[:macro] == :bear && trend[:medium] == :bear
      warn "[BybitSignal] Trend-only: short (Macro=bear Medium=bear)"
      { "direction" => "short", "confidence" => 0.70,
        "reasoning" => "trend-only: #{row["reasoning"]}",
        "timestamp" => row["timestamp"] }
    elsif trend[:macro] == :bull && trend[:medium] == :bull
      warn "[BybitSignal] Trend-only: long (Macro=bull Medium=bull)"
      { "direction" => "long", "confidence" => 0.70,
        "reasoning" => "trend-only: #{row["reasoning"]}",
        "timestamp" => row["timestamp"] }
    end
  rescue => e
    warn "[BybitSignal] trend_only_signal failed: #{e.message}"
    nil
  end

  # Fallback: if signal is stale, use the direction of the currently open trade.
  # The trades table has closed_at=NULL while a position is active — this is
  # source-of-truth for what bybit is actually doing right now.
  def self.open_trade_signal
    db = SQLite3::Database.new(BYBIT_DB, readonly: true)
    db.results_as_hash = true
    trade = db.execute(
      "SELECT direction FROM trades
       WHERE dry_run = 0 AND closed_at IS NULL
       ORDER BY id DESC LIMIT 1"
    ).first
    db.close
    return nil unless trade

    direction = trade["direction"].to_s
    return nil if direction.empty? || direction == "flat"

    warn "[BybitSignal] Using open trade direction: #{direction}"
    { "direction" => direction, "confidence" => 0.6,
      "reasoning" => "open position fallback (signal stale)",
      "timestamp" => Time.now.utc.iso8601 }
  rescue => e
    warn "[BybitSignal] open_trade_signal failed: #{e.message}"
    nil
  end
end
