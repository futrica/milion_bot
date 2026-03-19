require "faraday"
require "json"
require "time"
require "dotenv/load"
require_relative "order_executor"

SIDE = :buy
SIZE = 1.0

# --- Find active market (try current and surrounding windows) ---
gamma   = Faraday.new(url: "https://gamma-api.polymarket.com")
now     = Time.now
windows = [-300, 0, 300, 600].map { |o| (now.to_i / 300) * 300 + o }

event = market = slug = nil
windows.each do |ts|
  s = "btc-updown-5m-#{ts}"
  r = gamma.get("/events", { slug: s })
  e = JSON.parse(r.body)&.first
  next unless e
  m = e["markets"]&.find { |x| x["active"] && !x["closed"] && x["acceptingOrders"] }
  next unless m
  end_t = Time.parse(m["endDate"]) rescue nil
  next unless end_t && end_t > now
  event = e; market = m; slug = s
  puts "Found active market: #{s} (closes #{end_t})"
  break
end

abort "No active market found!" unless market

outcomes  = JSON.parse(market["outcomes"])
token_ids = JSON.parse(market["clobTokenIds"])
puts "Market : #{event["title"]}"

# UP = index 0, DOWN = index 1 — try UP to get a normal price
up_token_id = token_ids[0]
puts "UP token_id: #{up_token_id[0..20]}..."

# --- Fetch current UP price from CLOB orderbook ---
clob = Faraday.new(url: "https://clob.polymarket.com")
books_resp = clob.post("/books", [{ token_id: up_token_id }].to_json,
                       "Content-Type" => "application/json")
books = JSON.parse(books_resp.body, symbolize_names: true)
book  = books.is_a?(Array) ? books.first : books

asks  = book[:asks] || []
bids  = book[:bids] || []
price = asks.map { |a| a[:price].to_f }.min
# If no asks, use best bid + 0.01 (limit buy above market)
price ||= (bids.map { |b| b[:price].to_f }.max || 0.5) + 0.01
abort "No prices in UP orderbook" if price <= 0

puts "UP best ask price: #{price}"

# Fetch fee rate for this token
fee_resp = clob.get("/fee-rate", { token_id: up_token_id })
fee_data = JSON.parse(fee_resp.body, symbolize_names: true) rescue {}
fee_rate = (fee_data[:fee_rate].to_f * 10000).to_i   # convert to bps
puts "Fee rate: #{fee_rate} bps (#{fee_data.inspect})"

puts "Placing BUY UP $#{SIZE} @ #{price} ..."

# Use POLY_GNOSIS_SAFE (signatureType=2) — proxy wallet as maker
ENV["POLY_MAIN_ADDRESS"] = "0x6c506e7Ec85bD757991656A0fA029ba6b70316ef"

executor = OrderExecutor::Executor.new
result   = executor.place_order(
  token_id:  up_token_id,
  side:      SIDE,
  price:     price,
  size_usdc: SIZE
)

puts result.inspect
