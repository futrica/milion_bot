require "faraday"
require "json"

module SlackNotifier
  SLACK_API = "https://slack.com/api/"

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

  def self.format_scan(market:, scan_time:, yes_price:, no_price:, btc_delta:, analysis:, order: nil)
    signal_emoji = case analysis[:recommendation]&.to_s
                   when "BUY_YES" then ":large_green_circle:"
                   when "BUY_NO"  then ":red_circle:"
                   else                ":white_circle:"
                   end

    lines = [
      "*— Market Scan #{scan_time} UTC —*",
      "",
      "Market: #{market}",
      "YES: `#{yes_price}`  NO: `#{no_price}`",
      "BTC Δ5m: `#{btc_delta}`",
      "",
      "*— Claude Analysis —*",
      "",
      "P(up):  `#{analysis[:probability]}`",
      "Edge:   `#{analysis[:edge]}`",
      "Conf:   `#{analysis[:confidence]}`",
      "Signal: #{signal_emoji} *#{analysis[:recommendation]}*",
      "",
      "_#{analysis[:reasoning]}_"
    ]

    if order
      status_emoji = order[:status] == "filled" ? ":white_check_mark:" : ":hourglass:"
      lines += [
        "",
        "*— Execution —*",
        "",
        "Order:   #{order[:side]} @#{order[:price]} × $#{order[:size]}",
        "Status:  #{status_emoji} #{order[:status]}",
        "PnL 24h: `#{order[:pnl_24h]}`"
      ]
    end

    lines.join("\n")
  end
end
