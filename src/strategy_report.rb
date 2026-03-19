require_relative "database"

# Compara performance de cada estratégia testada.
# Uso:
#   bundle exec ruby src/strategy_report.rb           # dry-run apenas
#   bundle exec ruby src/strategy_report.rb --live    # live apenas
#   bundle exec ruby src/strategy_report.rb --all     # tudo

mode_flag = ARGV.first
dry_filter = case mode_flag
             when "--live" then "AND dry_run = 0"
             when "--all"  then ""
             else               "AND dry_run = 1"
             end
mode_label = case mode_flag
             when "--live" then "LIVE"
             when "--all"  then "ALL"
             else               "DRY-RUN"
             end

puts "\n#{"=" * 60}"
puts " milion_bot — Strategy Report [#{mode_label}]"
puts " #{Time.now.strftime("%Y-%m-%d %H:%M UTC")}"
puts "=" * 60

# ── Por estratégia ──────────────────────────────────────────
rows = Database.connection.execute(<<~SQL)
  SELECT
    COALESCE(strategy, 'unknown')              AS name,
    COUNT(*)                                   AS total,
    SUM(CASE WHEN result = 'win'  THEN 1 END)  AS wins,
    SUM(CASE WHEN result = 'loss' THEN 1 END)  AS losses,
    ROUND(SUM(pnl_usdc), 4)                    AS pnl,
    ROUND(AVG(CASE WHEN result IS NOT NULL
              THEN pnl_usdc END), 4)           AS avg_pnl
  FROM trades
  WHERE order_id IS NOT NULL AND result IS NOT NULL #{dry_filter}
  GROUP BY strategy
  ORDER BY pnl DESC
SQL

if rows.empty?
  puts "\nNenhum trade resolvido ainda.\n"
  exit
end

puts "\n%-18s  %5s  %4s  %5s  %8s  %8s  %7s" %
     ["Strategy", "Total", "Wins", "Loss", "WinRate", "PnL", "Avg/tr"]
puts "-" * 60

rows.each do |r|
  total   = r["total"].to_i
  wins    = r["wins"].to_i
  losses  = r["losses"].to_i
  pnl     = r["pnl"].to_f
  avg     = r["avg_pnl"].to_f
  rate    = total > 0 ? "#{(wins.to_f / total * 100).round(1)}%" : "—"
  pnl_s   = "#{pnl >= 0 ? "+" : ""}$#{pnl.round(4)}"
  avg_s   = "#{avg >= 0 ? "+" : ""}$#{avg.round(4)}"

  puts "%-18s  %5d  %4d  %5d  %7s  %8s  %7s" %
       [r["name"], total, wins, losses, rate, pnl_s, avg_s]
end

# ── Overall ─────────────────────────────────────────────────
total_row = Database.connection.get_first_row(<<~SQL)
  SELECT
    COUNT(*) AS total,
    SUM(CASE WHEN result = 'win' THEN 1 END) AS wins,
    ROUND(SUM(pnl_usdc), 4) AS pnl
  FROM trades WHERE order_id IS NOT NULL AND result IS NOT NULL #{dry_filter}
SQL

puts "-" * 60
total = total_row["total"].to_i
wins  = total_row["wins"].to_i
rate  = total > 0 ? "#{(wins.to_f / total * 100).round(1)}%" : "—"
pnl   = total_row["pnl"].to_f
puts "%-18s  %5d  %4d  %5d  %7s  %8s" %
     ["TOTAL", total, wins, total - wins, rate,
      "#{pnl >= 0 ? "+" : ""}$#{pnl.round(4)}"]

# ── Trades por estratégia ────────────────────────────────────
puts "\n\n#{"─" * 60}"
puts " Trades detalhados por estratégia"
puts "─" * 60

rows.each do |r|
  puts "\n[#{r["name"]}]"
  trades = Database.connection.execute(<<~SQL, [r["name"]])
    SELECT strftime('%H:%M', timestamp) as t, recommendation, yes_price,
           result, pnl_usdc
    FROM trades
    WHERE strategy = ? AND order_id IS NOT NULL #{dry_filter}
    ORDER BY timestamp ASC
  SQL
  trades.each do |t|
    pnl_s = t["pnl_usdc"] ? "#{t["pnl_usdc"].to_f >= 0 ? "+" : ""}$#{t["pnl_usdc"].to_f.round(4)}" : "pending"
    puts "  #{t["t"]}  #{t["recommendation"].ljust(8)}  UP:#{t["yes_price"].to_f.round(2).to_s.ljust(5)}  #{(t["result"] || "pending").ljust(7)}  #{pnl_s}"
  end
end

puts "\n"
