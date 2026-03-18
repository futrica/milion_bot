require "faraday"
require "json"
require "dotenv/load"
require_relative "analyst"
require_relative "slack_notifier"
require_relative "order_executor"

# Polymarket CLOB (Central Limit Order Book) public API
# Rate limits (market data endpoints): 1,500 req / 10s — no sleep needed.
#
# WebSocket alternative (real-time streaming, multiple assets in one connection):
#   wss://ws-subscriptions-clob.polymarket.com/ws/market
#   Subscribe with: { type: "market", assets_ids: [...], initial_dump: true }
#   Send PING every 10s; server replies PONG.
CLOB_BASE_URL = "https://clob.polymarket.com"
BINANCE_URL   = "https://api.binance.com"
TRADES_FILE   = ENV.fetch("TRADES_FILE", "/app/data/trades.json")
PARAMS_FILE   = ENV.fetch("PARAMS_FILE", "/app/config/trade_params.json")

module MarketScanner
  class Scanner
    def initialize(condition_id:, analysis_endpoint: nil)
      @condition_id      = condition_id
      @analysis_endpoint = analysis_endpoint
      @analyst           = Analyst::Client.new
      @executor          = ENV["WALLET_PRIVATE_KEY"] ? OrderExecutor::Executor.new : nil
      @clob = Faraday.new(url: CLOB_BASE_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end
    end

    def scan
      params    = load_params
      market    = fetch_market
      orderbook = fetch_orderbook_batch(market[:token_ids])
      btc       = fetch_btc_spot

      payload = build_payload(market, orderbook, btc)
      puts JSON.pretty_generate(payload)

      yes = orderbook.find { |o| o[:outcome] == "YES" }
      if yes && yes[:liquidity] >= params[:min_liquidity]
        run_analysis(market, yes, btc, params, payload)
      end

      post_to_analysis(payload) if @analysis_endpoint
      payload
    end

    private

    # -------------------------------------------------------------------------
    # Params (reloaded every scan so self_improve patches take effect immediately)
    # -------------------------------------------------------------------------
    def load_params
      defaults = { "min_edge" => 0.10, "max_position_usdc" => 100,
                   "min_liquidity" => 500, "min_confidence" => 0.7,
                   "scan_interval_seconds" => 10 }
      return defaults unless File.exist?(PARAMS_FILE)

      defaults.merge(JSON.parse(File.read(PARAMS_FILE)))
    rescue JSON::ParserError
      defaults
    end

    # -------------------------------------------------------------------------
    # Polymarket — market metadata
    # -------------------------------------------------------------------------
    def fetch_market
      resp = @clob.get("/markets/#{@condition_id}")
      data = JSON.parse(resp.body, symbolize_names: true)

      token_ids = data[:tokens]&.map { |t| t[:token_id] } || []
      { token_ids:, description: data[:question] }
    end

    # -------------------------------------------------------------------------
    # Polymarket — POST /books (batch, single round-trip for all outcomes)
    # -------------------------------------------------------------------------
    def fetch_orderbook_batch(token_ids)
      return [] if token_ids.empty?

      body  = token_ids.map { |id| { token_id: id } }
      resp  = @clob.post("/books", body)
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

    # -------------------------------------------------------------------------
    # Binance — BTC/USDT spot + 5-min delta (no API key required)
    # -------------------------------------------------------------------------
    def fetch_btc_spot
      conn  = Faraday.new(url: BINANCE_URL)
      resp  = conn.get("/api/v3/klines", symbol: "BTCUSDT", interval: "5m", limit: 2)
      klines = JSON.parse(resp.body)

      prev_close = klines[0][4].to_f
      curr_close = klines[1][4].to_f
      delta      = ((curr_close - prev_close) / prev_close * 100).round(2)

      { price: curr_close.round(2), delta_5m: delta }
    rescue => e
      warn "[MarketScanner] BTC spot fetch failed: #{e.message}"
      { price: nil, delta_5m: nil }
    end

    # -------------------------------------------------------------------------
    # Claude analysis + optional Slack notification + trade recording
    # -------------------------------------------------------------------------
    def run_analysis(market, yes_outcome, btc, params, payload)
      no_price = yes_outcome[:buy_price] ? (1 - yes_outcome[:buy_price]).round(4) : nil

      analysis = @analyst.analyze(
        market_question: market[:description],
        yes_price:       yes_outcome[:buy_price],
        no_price:,
        btc_price:       btc[:price],
        delta:           btc[:delta_5m]
      )
      return unless analysis

      confidence = analysis[:confidence].to_f
      edge       = analysis[:edge].to_f.abs

      if confidence >= params["min_confidence"] && edge >= params["min_edge"]
        order = execute_order(yes_outcome, analysis, params)
        record_trade(payload, analysis, order)
        notify_slack(market[:description], yes_outcome, btc, analysis, order)
      end
    end

    # -------------------------------------------------------------------------
    # Place order on Polymarket via CLOB API
    # -------------------------------------------------------------------------
    def execute_order(yes_outcome, analysis, params)
      return nil unless @executor

      side     = analysis[:recommendation].to_s == "BUY_YES" ? :buy : :sell
      token_id = yes_outcome[:token_id]
      price    = yes_outcome[:buy_price]
      size     = params["max_position_usdc"]

      @executor.place_order(token_id:, side:, price:, size_usdc: size)
    end

    # -------------------------------------------------------------------------
    # Persist trade to data/trades.json for self_improve.rb
    # -------------------------------------------------------------------------
    def record_trade(payload, analysis, order = nil)
      trades = File.exist?(TRADES_FILE) ? JSON.parse(File.read(TRADES_FILE), symbolize_names: true) : []
      trades << {
        condition_id:   @condition_id,
        timestamp:      payload[:timestamp],
        recommendation: analysis[:recommendation],
        probability:    analysis[:probability],
        edge:           analysis[:edge],
        confidence:     analysis[:confidence],
        yes_price:      payload[:market_price].find { |o| o[:outcome] == "YES" }&.dig(:buy_price),
        order_id:       order&.dig(:orderID),
        order_status:   order&.dig(:status),
        result:         nil  # filled in later when market resolves
      }
      File.write(TRADES_FILE, JSON.pretty_generate(trades))
    rescue => e
      warn "[MarketScanner] Could not record trade: #{e.message}"
    end

    # -------------------------------------------------------------------------
    # Slack notification (image 4 format)
    # -------------------------------------------------------------------------
    def notify_slack(description, yes_outcome, btc, analysis, order = nil)
      delta_str = btc[:delta_5m] ? "#{btc[:delta_5m] >= 0 ? '+' : ''}#{btc[:delta_5m]}%" : "N/A"
      no_price  = yes_outcome[:buy_price] ? (1 - yes_outcome[:buy_price]).round(4) : "N/A"

      order_info = order ? {
        side:    analysis[:recommendation],
        price:   yes_outcome[:buy_price],
        size:    order[:size] || "?",
        status:  order[:status],
        pnl_24h: "pending"
      } : nil

      msg = SlackNotifier.format_scan(
        market:    description,
        scan_time: Time.now.utc.strftime("%H:%M:%S"),
        yes_price: yes_outcome[:buy_price],
        no_price:,
        btc_delta: delta_str,
        analysis:,
        order:     order_info
      )
      SlackNotifier.send(msg)
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
    def best_price(levels, order = :desc)
      return nil if levels.nil? || levels.empty?

      prices = levels.map { |l| l[:price].to_f }
      order == :desc ? prices.max : prices.min
    end

    def total_liquidity(levels)
      return 0.0 if levels.nil? || levels.empty?

      levels.sum { |l| l[:price].to_f * l[:size].to_f }
    end

    def build_payload(market, orderbook, btc)
      {
        condition_id:    @condition_id,
        description:     market[:description],
        timestamp:       Time.now.utc.iso8601,
        btc:             btc,
        market_price:    orderbook,
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
    puts "[MarketScanner] Dry-run mode — Slack + trade recording disabled"
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
