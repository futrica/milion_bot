require "faraday"
require "json"
require_relative "database"

module SlackNotifier
  SLACK_API              = "https://slack.com/api/"
  SUMMARY_LOOKBACK_SECONDS = 3600  # envia a cada 1 hora

  def self.send(text)
    token   = ENV.fetch("SLACK_BOT_TOKEN")
    channel = ENV.fetch("SLACK_CHANNEL", "#milion-bot")

    conn = Faraday.new(url: SLACK_API) do |f|
      f.request  :json
      f.response :raise_error
      f.adapter  Faraday.default_adapter
    end

    conn.post(
      "chat.postMessage",
      { channel:, text:, unfurl_links: false },
      { "Authorization" => "Bearer #{token}" }
    )
  rescue Faraday::Error => e
    warn "[Slack] Failed to send message: #{e.message}"
  end

  def self.send_summary(dry_run: false)
    all_trades = Database.recent_trades(limit: 500)
    now        = Time.now.utc

    # Últimas 1h
    since_1h = now - SUMMARY_LOOKBACK_SECONDS
    last_1h   = all_trades.select { |t| t["result"] && Time.parse(t["timestamp"]) >= since_1h }

    # Hoje (desde meia-noite UTC)
    since_day = Time.utc(now.year, now.month, now.day)
    today     = all_trades.select { |t| t["result"] && Time.parse(t["timestamp"]) >= since_day }

    # Métricas 1h
    wins_1h = last_1h.count { |t| t["result"] == "win" }
    loss_1h = last_1h.count { |t| t["result"] == "loss" }
    pnl_1h  = last_1h.sum   { |t| t["pnl_usdc"].to_f }.round(2)

    # Métricas do dia
    wins_day  = today.count { |t| t["result"] == "win" }
    total_day = today.size
    pnl_day   = today.sum { |t| t["pnl_usdc"].to_f }.round(2)
    rate_day  = total_day > 0 ? (wins_day.to_f / total_day * 100).round(1) : nil

    pnl_day_str = "#{pnl_day >= 0 ? "+" : ""}$#{pnl_day}"
    pnl_1h_str  = "#{pnl_1h >= 0 ? "+" : ""}$#{pnl_1h}"
    rate_str    = rate_day ? "#{rate_day}% (#{wins_day}W #{total_day - wins_day}L)" : "sem trades"
    mode        = dry_run ? " _(dry run)_" : ""

    text = "*milion_bot#{mode} — #{now.strftime("%H:%M UTC")}*\n" \
           "\n" \
           "*Última 1h:*  #{wins_1h}W #{loss_1h}L  │  PnL #{pnl_1h_str}\n" \
           "*Hoje:*        #{rate_str}  │  PnL #{pnl_day_str}"

    send(text)
  rescue => e
    warn "[Slack] Summary failed: #{e.message}"
  end
end
