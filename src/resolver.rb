require "faraday"
require "json"
require "dotenv/load"
require_relative "database"

RESOLVER_CLOB_URL = "https://clob.polymarket.com"

# Checks Polymarket for resolved markets, backfills outcome + PnL in the DB.
# Called automatically from the scanner loop when a new market starts.
module Resolver
  class << self
    def run(condition_id: nil)
      pending = condition_id ?
        Database.unresolved_scans.select { |s| s["condition_id"] == condition_id } :
        Database.unresolved_scans

      return if pending.empty?

      pending.group_by { |s| s["condition_id"] }.each do |cid, group|
        winner = fetch_winner(cid)
        next if winner.nil?

        group.each do |scan|
          # Both YES and Up are the "first" outcome (probability > 0.5 = predict first)
          predicted_first = scan["claude_probability"].to_f > 0.5
          actual_first    = winner == "Up" || winner == "Yes" || winner == "YES"
          outcome         = (predicted_first == actual_first) ? "correct" : "incorrect"
          Database.resolve_scan(scan["id"], outcome)
        end

        resolve_trade_pnl(cid, winner)
        puts "[Resolver] #{cid[0..12]}... → winner: #{winner}"
      end

      Database.dump
    end

    private

    def fetch_winner(condition_id)
      conn = Faraday.new(url: RESOLVER_CLOB_URL)
      resp = conn.get("/markets/#{condition_id}")
      data = JSON.parse(resp.body, symbolize_names: true)

      return nil if data[:active] != false && data[:closed] != true

      winning_token = data[:tokens]&.find { |t| t[:winner] == true }
      winning_token&.dig(:outcome)
    rescue => e
      warn "[Resolver] #{e.message}"
      nil
    end

    def resolve_trade_pnl(condition_id, winner)
      trades = Database.recent_trades(limit: 100)
        .select { |t| t["condition_id"] == condition_id && t["result"].nil? }

      trades.each do |trade|
        rec       = trade["recommendation"].to_s
        size_usdc = trade["size_usdc"].to_f
        yes_price = trade["yes_price"].to_f
        next if size_usdc.zero? || yes_price.zero?

        # BUY_YES = bought UP at yes_price; BUY_NO = bought DOWN at (1 - yes_price)
        bet_on_first = rec == "BUY_YES"
        won          = bet_on_first == (winner == "Up" || winner == "Yes" || winner == "YES")

        entry    = bet_on_first ? yes_price : (1.0 - yes_price)
        result   = won ? "win" : "loss"
        pnl_usdc = won ? (size_usdc / entry) - size_usdc : -size_usdc

        Database.update_trade_result(condition_id, result, pnl_usdc.round(4))
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require "dotenv/load"
  Resolver.run
end
