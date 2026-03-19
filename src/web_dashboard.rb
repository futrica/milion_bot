require "sinatra"
require "sinatra/json"
require "dotenv/load"
require "json"
require_relative "database"

PARAMS_FILE = ENV.fetch("PARAMS_FILE", "config/trade_params.json")

set :port,       4567
set :bind,       "0.0.0.0"
set :public_folder, File.join(__dir__, "..", "public")

def load_params
  JSON.parse(File.read(PARAMS_FILE))
rescue
  {}
end

# ── API endpoints ────────────────────────────────────────────────────────────

get "/api/stats" do
  params_cfg     = load_params
  initial        = params_cfg.fetch("initial_balance", 100.0).to_f
  win            = Database.win_rate
  acc            = Database.scan_accuracy
  pnl            = Database.total_pnl || 0.0
  trades         = Database.recent_trades(limit: 50)
  scans          = Database.recent_scans(limit: 30)

  json(
    win_rate:        win,
    scan_acc:        acc,
    pnl:             pnl.round(4),
    balance:         (initial + pnl).round(2),
    initial_balance: initial,
    trades:          trades,
    scans:           scans
  )
end

post "/api/config/balance" do
  body   = JSON.parse(request.body.read)
  amount = body["initial_balance"].to_f
  return halt(400, "Invalid amount") if amount <= 0

  cfg = load_params
  cfg["initial_balance"] = amount
  cfg["updated_at"]      = Time.now.utc.iso8601
  File.write(PARAMS_FILE, JSON.pretty_generate(cfg))
  json(ok: true, initial_balance: amount)
rescue => e
  halt 500, e.message
end

get "/" do
  send_file File.join(settings.public_folder, "index.html")
end
