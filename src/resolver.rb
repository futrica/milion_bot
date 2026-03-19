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
      # Collect condition_ids from both unresolved scans AND unresolved trades
      pending_scans = condition_id ?
        Database.unresolved_scans.select { |s| s["condition_id"] == condition_id } :
        Database.unresolved_scans

      unresolved_trade_cids = Database.recent_trades(limit: 200)
        .select { |t| t["result"].nil? && !t["order_id"].nil? }
        .map { |t| t["condition_id"] }
        .uniq

      filter_cid = condition_id
      all_cids = (pending_scans.map { |s| s["condition_id"] } + unresolved_trade_cids)
        .uniq
        .then { |cids| filter_cid ? cids.select { |c| c == filter_cid } : cids }

      return if all_cids.empty?

      scans_by_cid = pending_scans.group_by { |s| s["condition_id"] }

      all_cids.each do |cid|
        result = fetch_winner(cid)
        next if result.nil?

        winner        = result[:winner]
        first_outcome = result[:first_outcome]

        # first_outcome is outcomes[0] from the CLOB — it may be "Up", "Down", "Yes", etc.
        # We compare directly instead of assuming outcomes[0] is always "Up"/"Yes".
        first_won = winner == first_outcome

        (scans_by_cid[cid] || []).each do |scan|
          predicted_first = scan["claude_probability"].to_f > 0.5
          outcome         = (predicted_first == first_won) ? "correct" : "incorrect"
          Database.resolve_scan(scan["id"], outcome)
        end

        resolve_trade_pnl(cid, winner, first_outcome)
        puts "[Resolver] #{cid[0..12]}... → winner: #{winner} (first_outcome: #{first_outcome})"
      end

      Database.dump
    end

    private

    def fetch_winner(condition_id)
      conn = Faraday.new(url: RESOLVER_CLOB_URL)
      resp = conn.get("/markets/#{condition_id}")
      data = JSON.parse(resp.body, symbolize_names: true)

      return nil if data[:active] != false && data[:closed] != true

      tokens        = data[:tokens] || []
      first_outcome = tokens.first&.dig(:outcome)
      winning_token = tokens.find { |t| t[:winner] == true }
      return nil unless winning_token

      { winner: winning_token[:outcome], first_outcome: first_outcome }
    rescue => e
      warn "[Resolver] #{e.message}"
      nil
    end

    def resolve_trade_pnl(condition_id, winner, first_outcome)
      trades = Database.recent_trades(limit: 100)
        .select { |t| t["condition_id"] == condition_id && t["result"].nil? && !t["order_id"].nil? }

      trades.each do |trade|
        rec        = trade["recommendation"].to_s
        size_usdc  = trade["size_usdc"].to_f
        shares     = trade["shares"].to_f   # actual shares received at fill
        fill_price = trade["fill_price"].to_f
        yes_price  = trade["yes_price"].to_f
        next if size_usdc.zero?

        bet_on_first = rec == "BUY_YES"
        won          = bet_on_first == (winner == first_outcome)

        # Use actual fill data when available, fall back to analysis price
        if won
          pnl_usdc = if shares > 0
            shares - size_usdc   # shares pay $1 each at resolution; cost = size_usdc
          elsif fill_price > 0
            (size_usdc / fill_price) - size_usdc
          else
            entry = bet_on_first ? yes_price : (1.0 - yes_price)
            entry > 0 ? (size_usdc / entry) - size_usdc : 0.0
          end
        else
          pnl_usdc = -size_usdc
        end

        result = won ? "win" : "loss"
        Database.update_trade_result(condition_id, result, pnl_usdc.round(4))
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require "dotenv/load"
  Resolver.run
end
