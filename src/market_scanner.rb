require "faraday"
require "json"
require "dotenv/load"

# Polymarket CLOB (Central Limit Order Book) public API
# Rate limits (market data endpoints): 1,500 req / 10s — no sleep needed.
#
# WebSocket alternative (real-time streaming, multiple assets in one connection):
#   wss://ws-subscriptions-clob.polymarket.com/ws/market
#   Subscribe with: { type: "market", assets_ids: [...], initial_dump: true }
#   Send PING every 10s; server replies PONG.
CLOB_BASE_URL = "https://clob.polymarket.com"

module MarketScanner
  class Scanner
    def initialize(condition_id:, analysis_endpoint: nil)
      @condition_id     = condition_id
      @analysis_endpoint = analysis_endpoint
      @clob = Faraday.new(url: CLOB_BASE_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end
    end

    def scan
      market    = fetch_market
      orderbook = fetch_orderbook_batch(market[:token_ids])

      payload = build_payload(market, orderbook)
      puts JSON.pretty_generate(payload)

      post_to_analysis(payload) if @analysis_endpoint
      payload
    end

    private

    # GET /markets/{condition_id}
    def fetch_market
      resp = @clob.get("/markets/#{@condition_id}")
      data = JSON.parse(resp.body, symbolize_names: true)

      token_ids = data[:tokens]&.map { |t| t[:token_id] } || []
      { token_ids:, description: data[:question] }
    end

    # POST /books — single request for all token IDs (batch endpoint).
    # Returns the same shape as multiple GET /orderbook calls but in one round-trip.
    def fetch_orderbook_batch(token_ids)
      return [] if token_ids.empty?

      body = token_ids.map { |id| { token_id: id } }
      resp = @clob.post("/books", body)
      books = JSON.parse(resp.body, symbolize_names: true)

      books.map.with_index do |book, idx|
        best_bid = best_price(book[:bids])
        best_ask = best_price(book[:asks], :asc)
        liquidity = total_liquidity(book[:bids]) + total_liquidity(book[:asks])

        {
          outcome:    idx == 0 ? "YES" : "NO",
          token_id:   book[:asset_id],
          buy_price:  best_ask,
          sell_price: best_bid,
          spread:     best_ask && best_bid ? (best_ask - best_bid).round(4) : nil,
          liquidity:  liquidity.round(2)
        }
      end
    end

    def best_price(levels, order = :desc)
      return nil if levels.nil? || levels.empty?

      prices = levels.map { |l| l[:price].to_f }
      order == :desc ? prices.max : prices.min
    end

    def total_liquidity(levels)
      return 0.0 if levels.nil? || levels.empty?

      levels.sum { |l| l[:price].to_f * l[:size].to_f }
    end

    def build_payload(market, orderbook)
      {
        condition_id:  @condition_id,
        description:   market[:description],
        timestamp:     Time.now.utc.iso8601,
        market_price:  orderbook,
        total_liquidity: orderbook.sum { |o| o[:liquidity] }.round(2)
      }
    end

    def post_to_analysis(payload)
      conn = Faraday.new do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end

      resp = conn.post(@analysis_endpoint, payload.to_json, "Content-Type" => "application/json")
      puts "[MarketScanner] POST #{@analysis_endpoint} → #{resp.status}"
    rescue Faraday::Error => e
      warn "[MarketScanner] Failed to POST to analysis endpoint: #{e.message}"
    end
  end
end

# --- CLI entry point ---
if __FILE__ == $PROGRAM_NAME
  condition_id      = ARGV[0] || ENV.fetch("CONDITION_ID")
  analysis_endpoint = ENV["ANALYSIS_ENDPOINT"]
  interval          = (ENV["SCAN_INTERVAL"] || 10).to_i
  dry_run           = ARGV.include?("--dry-run")

  scanner = MarketScanner::Scanner.new(
    condition_id:,
    analysis_endpoint: dry_run ? nil : analysis_endpoint
  )

  if dry_run
    puts "[MarketScanner] Dry-run mode — POST disabled"
    scanner.scan
  else
    puts "[MarketScanner] Scanning every #{interval}s (Ctrl+C to stop)"
    loop do
      begin
        scanner.scan
      rescue => e
        warn "[MarketScanner] Error: #{e.message}"
      end
      sleep interval
    end
  end
end
