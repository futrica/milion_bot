require "faraday"
require "json"
require "time"

GAMMA_API = "https://gamma-api.polymarket.com"

# Finds the active "Bitcoin Up or Down - 5 Minutes" market whose
# measurement window is current or soonest upcoming.
#
# Polymarket slug format: "btc-updown-5m-{unix_timestamp}"
# where unix_timestamp = measurement window START (multiples of 300s).
#
# Strategy: construct slugs for current + next 2 windows mathematically,
# fetch each by exact slug, return first one with a valid active market.
module MarketFinder
  SLUG_PREFIX = "btc-updown-5m"

  def self.current
    now     = Time.now
    # Try current window and next 2 windows (0, 5, 10 min ahead)
    windows = [0, 300, 600].map { |offset| (now.to_i / 300) * 300 + offset }

    windows.each do |window_ts|
      slug  = "#{SLUG_PREFIX}-#{window_ts}"
      event = fetch_event(slug)
      next unless event

      market = event["markets"]&.find { |m| m["active"] && !m["closed"] && m["acceptingOrders"] }
      next unless market

      end_t   = Time.parse(market["endDate"])  rescue nil
      start_t = event["startTime"] ? Time.parse(event["startTime"]) : nil rescue nil
      next unless end_t && end_t > now

      outcomes  = JSON.parse(market["outcomes"])
      token_ids = JSON.parse(market["clobTokenIds"])

      # Normalize so outcomes[0] is always the "positive" outcome (Up/Yes).
      # Polymarket Gamma API does not guarantee ordering; the CLOB always uses
      # Up/Yes as the first token, so we must align to avoid win/loss inversions.
      if outcomes[0] =~ /\A(down|no)\z/i
        outcomes  = outcomes.reverse
        token_ids = token_ids.reverse
      end

      return {
        condition_id: market["conditionId"],
        question:     event["title"],
        slug:         event["slug"],
        url:          "https://polymarket.com/event/#{event["slug"]}",
        end_date:     end_t,
        start_time:   start_t,
        outcomes:,
        token_ids:,
        liquidity:    event["liquidityClob"].to_f
      }
    end

    nil
  rescue => e
    warn "[MarketFinder] #{e.message}"
    nil
  end

  private

  def self.fetch_event(slug)
    conn = Faraday.new(url: GAMMA_API)
    resp = conn.get("/events", { slug: slug })
    events = JSON.parse(resp.body)
    events.is_a?(Array) ? events.first : nil
  rescue => e
    warn "[MarketFinder] fetch #{slug}: #{e.message}"
    nil
  end
end
