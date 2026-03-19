require "io/console"
require_relative "database"

module Dashboard
  MAX_LOG_LINES = 80

  G = "\e[32m"; R = "\e[31m"; Y = "\e[33m"
  C = "\e[36m"; M = "\e[35m"; BOLD = "\e[1m"; RST = "\e[0m"

  SIGNAL_COLOR = { "BUY_YES" => G, "BUY_NO" => R, "HOLD" => Y }.freeze
  PHASE_COLOR  = { "OBSERVE" => C, "ACT" => M }.freeze

  @logs        = []
  @current_cid = nil

  # ── Terminal inner width (cols - 2 for the ║ borders) ───────────────────
  def self.w
    cols = IO.console&.winsize&.last || 120
    [cols - 2, 60].max
  end

  # ── Accumulate logs per window, clear when window changes ───────────────
  def self.log_scan(market:, btc:, up:, analysis:, phase:, time_left:, start_time: nil,
                    acted:, dry_run: false, min_confidence: 0.70, min_edge: 0.10, strategy: nil)
    cid = market[:condition_id]
    if @current_cid != cid
      @logs        = []
      @current_cid = cid
    end

    ts      = Time.now.utc.strftime("%H:%M:%S")
    ph      = phase.to_s.upcase
    acted_s = acted && ph == "OBSERVE" ? " #{G}▶ EARLY#{RST}" :
              acted                   ? " #{G}▶ ORDER#{RST}" : ""
    dry_s   = dry_run ? " #{Y}[dry]#{RST}"   : ""

    now = Time.now
    timing = if start_time && now < start_time
      secs = (start_time - now).to_i
      "starts in #{secs / 60}:#{(secs % 60).to_s.rjust(2, '0')}"
    else
      "#{time_left / 60}:#{(time_left % 60).to_s.rjust(2, '0')} left"
    end

    if analysis
      rec    = analysis[:recommendation].to_s
      conf_v = analysis[:confidence].to_f
      edge_v = analysis[:edge].to_f
      conf_c = conf_v >= min_confidence ? G : R
      edge_c = edge_v.abs >= min_edge   ? G : R
      signal = "#{SIGNAL_COLOR[rec]}#{rec.ljust(7)}#{RST}  conf:#{conf_c}#{analysis[:confidence]}#{RST}  edge:#{edge_c}#{analysis[:edge]}#{RST}"
    else
      signal = "#{Y}#{"collecting...".ljust(7)}#{RST}  #{timing}"
      timing = nil
    end

    @logs << "#{ts}  #{PHASE_COLOR[ph]}#{ph.ljust(7)}#{RST}" \
             "  UP:#{up[:buy_price]}  BTC:$#{btc[:price]}  Δ#{btc[:delta_5m].to_s.rjust(7)}%" \
             "  #{signal}" \
             "#{timing ? "  #{timing}" : ""}#{acted_s}#{dry_s}"
  end

  # ── Clear screen + redraw everything ────────────────────────────────────
  def self.print(next_scan_in: nil, balance_usdc: nil, market_url: nil, dry_run: false,
                 min_confidence: 0.70, min_edge: 0.10)
    win  = Database.win_rate
    acc  = Database.scan_accuracy
    last = Database.recent_scans(limit: 1).first
    pnl  = Database.total_pnl

    $stdout.print "\e[H\e[2J"   # clear screen, cursor home

    puts bar("╔", "╗")
    title = dry_run ? "#{BOLD}milion_bot#{RST}  —  BTC Up/Down 5m  —  #{Y}DRY RUN#{RST}" \
                    : "#{BOLD}milion_bot#{RST}  —  BTC Up/Down 5m  —  Polymarket"
    puts mid(title)
    puts bar("╠", "╣")

    if last
      puts row("Market",    last["market_question"].to_s)
      puts row("Link",      market_url || "—")
      bal_label = dry_run ? "#{Y}[sim]#{RST} " : ""
      bal = balance_usdc ? "#{bal_label}#{G}$#{balance_usdc.round(2)} USDC#{RST}" : "—"
      puts row("Balance",   bal, raw: true)
      puts row("Next scan", next_scan_in ? "in #{next_scan_in}s" : "—")
    else
      puts row("Status", "Waiting for first scan...")
    end

    puts bar("╠", "╣")

    if win
      pnl_s  = pnl ? "#{pnl >= 0 ? G + "+" : R}$#{pnl.round(2)}#{RST}" : "pending"
      rate_c = win[:rate] >= 0.55 ? G : R
      puts row("Trades",   "#{win[:total]} total  │  #{win[:wins]}W #{win[:total]-win[:wins]}L  │  #{rate_c}#{(win[:rate]*100).round(1)}% win rate#{RST}", raw: true)
      puts row("PnL",      pnl_s, raw: true)
    else
      puts row("Trades",   "No closed trades yet")
      puts row("PnL",      "—")
    end

    acc_s = acc ? "#{(acc[:accuracy]*100).round(1)}%  (#{acc[:correct]}/#{acc[:total]} resolved)" : "—"
    puts row("Scan acc",  acc_s)

    # ── Entry thresholds ──
    puts bar("╠", "╣")
    thresh = "ACT: conf #{G}≥ #{min_confidence}#{RST}  edge #{G}≥ #{min_edge}#{RST}" \
             "   #{Y}│#{RST}   EARLY: conf #{G}≥ 0.82#{RST}  edge #{G}≥ 0.25#{RST}  after #{G}5pts#{RST}" \
             "   #{Y}│#{RST}   UP #{G}0.15–0.85#{RST}  time #{G}> 30s#{RST}"
    puts mid(thresh)

    puts bar("╠", "╣")
    puts mid("Scan log  (#{@logs.size} scans this window)")
    puts bar("╠", "╣")

    if @logs.empty?
      puts row("", "(no scans yet)")
    else
      @logs.each { |l| puts log_row(l) }
    end

    puts bar("╚", "╝")
  end

  private

  def self.bar(l, r) = "#{l}#{"═" * w}#{r}"

  def self.mid(text)
    plain = text.gsub(/\e\[[0-9;]*m/, "")
    pad   = [(w - plain.length) / 2, 0].max
    "║#{" " * pad}#{text}#{" " * [w - pad - plain.length, 0].max}║"
  end

  def self.row(label, value, raw: false)
    prefix = "  #{label.ljust(10)}  "
    plain  = raw ? value.gsub(/\e\[[0-9;]*m/, "") : value.to_s
    val    = raw ? value : value.to_s[0, w - prefix.length - 1]
    pad    = [w - prefix.length - plain.length - 1, 0].max
    "║#{prefix}#{val}#{" " * pad}║"
  end

  def self.log_row(line)
    plain = line.gsub(/\e\[[0-9;]*m/, "")
    avail = w - 2
    if plain.length <= avail
      pad = avail - plain.length
      "║  #{line}#{" " * pad}║"
    else
      "║  #{plain[0, avail]}║"
    end
  end
end
