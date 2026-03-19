require "faraday"
require "json"
require "dotenv/load"
require_relative "analyst"
require_relative "slack_notifier"
require_relative "order_executor"
require_relative "database"
require_relative "market_finder"
require_relative "resolver"
require_relative "dashboard"

CLOB_BASE_URL   = "https://clob.polymarket.com"
BINANCE_URL     = "https://api.binance.com"
PARAMS_FILE     = ENV.fetch("PARAMS_FILE", "config/trade_params.json")
STRATEGIES_FILE = ENV.fetch("STRATEGIES_FILE", "config/strategies.json")

# Two-phase strategy per 5-min market window:
#
#  OBSERVE phase (time_left > strategy[:act_seconds_before_close]):
#    - Claude runs once at first detection of a new market
#    - Orderbook + BTC re-scanned every interval to track momentum
#    - No orders placed
#
#  ACT phase (time_left <= strategy[:act_seconds_before_close]):
#    - Execute Claude's cached recommendation if confidence + edge thresholds met
#    - Only one trade per market window
#    - Skip if time_left < strategy[:too_late_seconds]
#
# Strategies rotate automatically per market window (round-robin).
# Each scan/trade is tagged with the active strategy name for comparison.

module MarketScanner
  class Scanner
    def initialize
      @analyst  = Analyst::Client.new
      @executor = ENV["WALLET_PRIVATE_KEY"] ? OrderExecutor::Executor.new : nil
      @clob     = Faraday.new(url: CLOB_BASE_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end

      @current_market     = nil   # current MarketFinder result
      @market_analysis    = nil   # cached Claude analysis for this window
      @observe_series     = []    # time-series data collected during OBSERVE phase
      @traded_this_market = false
      @balance_usdc       = nil
      @balance_fetched_at = nil

      # Strategy rotation — cycles through all defined strategies, one per market window
      @strategies      = load_strategies
      @strategy_index  = 0
      @current_strategy = @strategies[@strategy_index]

      # Resolve any markets that closed while the bot was offline
      Resolver.run
    end

    def scan(dry_run: false)
      market = find_market
      return unless market

      base_params = load_params
      strategy    = @current_strategy
      # Strategy overrides base params for all threshold/timing keys
      params      = base_params.merge(strategy)

      now        = Time.now
      end_date   = market[:end_date]
      start_time = market[:start_time]
      time_left  = [(end_date - now).to_i, 0].max

      act_secs      = strategy.fetch("act_seconds_before_close", 90)
      too_late_secs = strategy.fetch("too_late_seconds", 30)

      measurement_started = start_time && now >= start_time
      phase_sym = (measurement_started && time_left <= act_secs) ? :act : :observe

      orderbook = fetch_orderbook(market[:token_ids], market[:outcomes])
      btc       = fetch_btc_spot
      up        = orderbook.find { |o| o[:outcome] == market[:outcomes][0] }
      down      = orderbook.find { |o| o[:outcome] == market[:outcomes][1] }

      unless up
        warn "[Scanner] No UP outcome in orderbook"
        return
      end

      if phase_sym == :observe
        @observe_series << {
          time:      Time.now.utc.strftime("%H:%M:%S"),
          up_price:  up[:buy_price],
          btc_price: btc[:price],
          delta_5m:  btc[:delta_5m]
        }
      end

      early_min_points = params.fetch("early_entry_min_series_points", 5)
      should_analyze   = @market_analysis.nil? && (
        phase_sym == :act ||
        (phase_sym == :observe && @observe_series.size >= early_min_points)
      )

      if should_analyze
        series = @observe_series.empty? ? [{
          time: Time.now.utc.strftime("%H:%M:%S"), up_price: up[:buy_price],
          btc_price: btc[:price], delta_5m: btc[:delta_5m]
        }] : @observe_series
        @market_analysis = @analyst.analyze_series(
          market_question: market[:question],
          series:          series
        )
      end

      analysis = @market_analysis
      phase    = phase_sym

      min_up   = params.fetch("min_up_price", 0.15)
      max_up   = params.fetch("max_up_price", 0.85)
      up_price = up[:buy_price].to_f
      price_ok = up_price >= min_up && up_price <= max_up

      act = false
      if !@traded_this_market && analysis && price_ok && time_left > too_late_secs
        confidence = analysis[:confidence].to_f
        edge       = analysis[:edge].to_f.abs

        act = if phase == :act
          confidence >= params.fetch("min_confidence", 0.70) &&
          edge       >= params.fetch("min_edge", 0.10)
        elsif phase == :observe
          confidence >= params.fetch("early_entry_min_confidence", 0.82) &&
          edge       >= params.fetch("early_entry_min_edge", 0.25)
        else
          false
        end
      end

      warn "[Scanner] Skipping: UP price #{up_price} out of range [#{min_up}, #{max_up}]" if !price_ok && analysis && !@traded_this_market

      record_scan(market, up, btc, analysis, act, strategy["name"], dry_run) if analysis
      balance = dry_run ? simulated_balance : fetch_balance_cached

      if act
        order = dry_run ? nil : execute_order(up, down, analysis, params)
        record_trade(market, up, analysis, order, params, strategy["name"], dry_run)
        @traded_this_market = true
      end

      Dashboard.log_scan(
        market:         market,
        btc:            btc,
        up:             up,
        analysis:       analysis,
        phase:          phase,
        time_left:      time_left,
        start_time:     start_time,
        acted:          act,
        dry_run:        dry_run,
        min_confidence: params.fetch("min_confidence", 0.70),
        min_edge:       params.fetch("min_edge", 0.10),
        strategy:       strategy["name"]
      )
      Dashboard.print(
        next_scan_in:   base_params["scan_interval_seconds"],
        balance_usdc:   balance,
        market_url:     market[:url],
        dry_run:        dry_run,
        min_confidence: params.fetch("min_confidence", 0.70),
        min_edge:       params.fetch("min_edge", 0.10)
      )
    end

    private

    # -----------------------------------------------------------------------
    # Market discovery — cached per window to avoid hammering Gamma API
    # -----------------------------------------------------------------------
    def find_market
      market = MarketFinder.current
      return nil unless market

      if @current_market.nil? || market[:condition_id] != @current_market[:condition_id]
        # New window — resolve previous, rotate strategy, reset state
        Resolver.run(condition_id: @current_market[:condition_id]) if @current_market
        @strategy_index   = (@strategy_index + 1) % @strategies.size
        @current_strategy = @strategies[@strategy_index]
        @current_market     = market
        @market_analysis    = nil
        @observe_series     = []
        @traded_this_market = false
        $stderr.puts "\n[Scanner] ▶ New window: #{market[:question]}  [strategy: #{@current_strategy["name"]}]"
      end

      @current_market
    end

    # -----------------------------------------------------------------------
    # Strategies — loaded once, rotated per market window
    # -----------------------------------------------------------------------
    def load_strategies
      return default_strategies unless File.exist?(STRATEGIES_FILE)

      JSON.parse(File.read(STRATEGIES_FILE)).reject { |s| s["_inactive"] }
    rescue JSON::ParserError
      default_strategies
    end

    def default_strategies
      [{ "name" => "standard_90s", "act_seconds_before_close" => 90,
         "too_late_seconds" => 30, "min_confidence" => 0.70,
         "min_edge" => 0.10, "min_up_price" => 0.15, "max_up_price" => 0.85,
         "early_entry_min_confidence" => 0.82, "early_entry_min_edge" => 0.25,
         "early_entry_min_series_points" => 5 }]
    end

    # -----------------------------------------------------------------------
    # Params
    # -----------------------------------------------------------------------
    def load_params
      defaults = { "min_edge" => 0.10, "max_position_usdc" => 10,
                   "min_liquidity" => 500, "min_confidence" => 0.7,
                   "scan_interval_seconds" => 30 }
      return defaults unless File.exist?(PARAMS_FILE)

      defaults.merge(JSON.parse(File.read(PARAMS_FILE)))
    rescue JSON::ParserError, Errno::ENOENT
      defaults
    end

    # -----------------------------------------------------------------------
    # Orderbook — POST /books (one round-trip for all outcomes)
    # -----------------------------------------------------------------------
    def fetch_orderbook(token_ids, outcomes)
      return [] if token_ids.empty?

      body  = token_ids.map { |id| { token_id: id } }
      resp  = @clob.post("/books", body)
      books = JSON.parse(resp.body, symbolize_names: true)

      books.map.with_index do |book, idx|
        best_bid  = best_price(book[:bids])
        best_ask  = best_price(book[:asks], :asc)
        liquidity = total_liquidity(book[:bids]) + total_liquidity(book[:asks])

        {
          outcome:    outcomes[idx] || (idx == 0 ? "UP" : "DOWN"),
          token_id:   book[:asset_id],
          buy_price:  best_ask,
          sell_price: best_bid,
          spread:     best_ask && best_bid ? (best_ask - best_bid).round(4) : nil,
          liquidity:  liquidity.round(2)
        }
      end
    end

    # -----------------------------------------------------------------------
    # BTC spot price + 5-min momentum from Binance
    # -----------------------------------------------------------------------
    def fetch_btc_spot
      conn   = Faraday.new(url: BINANCE_URL)
      resp   = conn.get("/api/v3/klines", symbol: "BTCUSDT", interval: "5m", limit: 2)
      klines = JSON.parse(resp.body)

      prev_close = klines[0][4].to_f
      curr_close = klines[1][4].to_f
      delta      = ((curr_close - prev_close) / prev_close * 100).round(4)

      { price: curr_close.round(2), delta_5m: delta }
    rescue => e
      warn "[Scanner] BTC fetch failed: #{e.message}"
      { price: nil, delta_5m: nil }
    end

    # -----------------------------------------------------------------------
    # Simulated balance for dry-run: $100 bankroll + resolved PnL
    # -----------------------------------------------------------------------
    def simulated_balance
      pnl = Database.total_pnl || 0.0
      100.0 + pnl
    end

    # -----------------------------------------------------------------------
    # Wallet balance — cached for 60s to avoid unnecessary auth calls
    # -----------------------------------------------------------------------
    def fetch_balance_cached
      return @balance_usdc if @balance_fetched_at && (Time.now - @balance_fetched_at) < 60

      # Query USDC.e balance of proxy wallet directly from Polygon blockchain
      # Funds live in the proxy wallet (Gnosis Safe), not the operator key
      proxy  = ENV["POLY_MAIN_ADDRESS"]
      return nil unless proxy && !proxy.empty?

      usdc_contract = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
      padded_addr   = proxy.delete_prefix("0x").downcase.rjust(64, "0")
      data          = "0x70a08231" + padded_addr   # balanceOf(address)

      rpc = Faraday.new(url: "https://polygon-bor-rpc.publicnode.com") { |f| f.request :json; f.adapter Faraday.default_adapter }
      resp = rpc.post("/", { jsonrpc: "2.0", method: "eth_call",
                             params: [{ to: usdc_contract, data: data }, "latest"], id: 1 })
      result = JSON.parse(resp.body, symbolize_names: true)
      raise "RPC error: #{result[:error]}" if result[:error]

      hex = result[:result].delete_prefix("0x")
      @balance_usdc = hex.to_i(16).to_f / 1_000_000
      @balance_fetched_at = Time.now
      @balance_usdc
    rescue => e
      warn "[Scanner] Balance fetch failed: #{e.message}"
      @balance_usdc
    end

    # -----------------------------------------------------------------------
    # Order execution
    # -----------------------------------------------------------------------
    def execute_order(up_outcome, down_outcome, analysis, params)
      return nil unless @executor

      buy_yes  = analysis[:recommendation].to_s == "BUY_YES"
      outcome  = buy_yes ? up_outcome : down_outcome
      token_id = outcome[:token_id]
      price    = outcome[:buy_price]
      size     = params["max_position_usdc"]

      @executor.place_order(token_id:, side: :buy, price:, size_usdc: size)
    end

    # -----------------------------------------------------------------------
    # Persist trade to DB
    # -----------------------------------------------------------------------
    def record_trade(market, up_outcome, analysis, order, params, strategy_name = nil, dry_run = false)
      Database.insert_trade(
        condition_id:   market[:condition_id],
        timestamp:      Time.now.utc.iso8601,
        recommendation: analysis[:recommendation].to_s,
        probability:    analysis[:probability].to_f,
        edge:           analysis[:edge].to_f,
        confidence:     analysis[:confidence].to_f,
        yes_price:      up_outcome[:buy_price],
        size_usdc:      params["max_position_usdc"].to_f,
        order_id:       order&.dig(:orderID),
        order_status:   order&.dig(:status),
        result:         nil,
        pnl_usdc:       nil,
        fill_price:     order ? begin
                          making = order[:makingAmount].to_f
                          taking = order[:takingAmount].to_f
                          taking > 0 ? (making / taking).round(6) : nil
                        end : nil,
        shares:         order ? order[:takingAmount].to_f / 1_000_000 : nil,
        strategy:       strategy_name,
        dry_run:        dry_run ? 1 : 0
      )
      Database.dump
    rescue => e
      warn "[Scanner] Could not record trade: #{e.message}"
    end

    # -----------------------------------------------------------------------
    # Persist every Claude analysis (including HOLDs)
    # -----------------------------------------------------------------------
    def record_scan(market, up_outcome, btc, analysis, action_taken, strategy_name = nil, dry_run = false)
      Database.insert_scan(
        condition_id:       market[:condition_id],
        market_question:    market[:question],
        timestamp:          Time.now.utc.iso8601,
        end_date:           market[:end_date].iso8601,
        btc_price:          btc[:price].to_f,
        yes_price:          up_outcome[:buy_price].to_f,
        no_price:           up_outcome[:buy_price] ? (1 - up_outcome[:buy_price]).round(4) : nil,
        liquidity:          up_outcome[:liquidity].to_f,
        claude_probability: analysis[:probability].to_f,
        claude_edge:        analysis[:edge].to_f,
        claude_confidence:  analysis[:confidence].to_f,
        recommendation:     analysis[:recommendation].to_s,
        reasoning:          analysis[:reasoning].to_s,
        action_taken:       action_taken ? 1 : 0,
        resolved:           0,
        outcome:            nil,
        strategy:           strategy_name,
        dry_run:            dry_run ? 1 : 0
      )
      Database.dump
    rescue => e
      warn "[Scanner] Could not record scan: #{e.message}"
    end

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------
    def best_price(levels, order = :desc)
      return nil if levels.nil? || levels.empty?

      prices = levels.map { |l| l[:price].to_f }
      order == :desc ? prices.max : prices.min
    end

    def total_liquidity(levels)
      return 0.0 if levels.nil? || levels.empty?

      levels.sum { |l| l[:price].to_f * l[:size].to_f }
    end
  end
end

# --- CLI entry point ---
if __FILE__ == $PROGRAM_NAME
  dry_run  = ARGV.include?("--dry-run")
  interval = (ENV["SCAN_INTERVAL"] || 30).to_i
  scanner  = MarketScanner::Scanner.new

  label = dry_run ? "DRY-RUN (simulated $100 bankroll, $1/trade)" : "LIVE"
  puts "[Scanner] #{label} — BTC Up/Down 5m — aligned to #{interval}s grid (Ctrl+C to stop)"

  # Background thread: send Slack summary every SUMMARY_LOOKBACK_SECONDS
  Thread.new do
    summary_interval = SlackNotifier::SUMMARY_LOOKBACK_SECONDS
    loop do
      sleep summary_interval
      SlackNotifier.send_summary(dry_run: dry_run)
    end
  end

  loop do
    begin
      scanner.scan(dry_run: dry_run)
    rescue => e
      warn "[Scanner] Error: #{e.message}"
      warn e.backtrace.first(3).join("\n")
    end
    # Sleep until next exact interval boundary (e.g. :00, :10, :20, :30...)
    now       = Time.now.to_f
    next_tick = (now / interval).ceil * interval
    sleep_for = next_tick - now
    sleep [sleep_for, 0.1].max
  end
end
