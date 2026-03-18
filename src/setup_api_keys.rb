#!/usr/bin/env ruby
# One-time script to derive Polymarket L2 API credentials from your wallet.
# Usage: ruby src/setup_api_keys.rb
#
require "eth"
require "faraday"
require "json"
require "dotenv/load"
require_relative "crypto"

CLOB_BASE_URL = "https://clob.polymarket.com"
CHAIN_ID      = 137
AUTH_MESSAGE  = "This message attests that I control the given wallet"

# Use eth gem's built-in EIP-712 typed data support
def build_l1_signature(key, timestamp, nonce: 0)
  typed_data = {
    types: {
      EIP712Domain: [
        { name: "name",    type: "string"  },
        { name: "version", type: "string"  },
        { name: "chainId", type: "uint256" }
      ],
      ClobAuth: [
        { name: "address",   type: "address" },
        { name: "timestamp", type: "string"  },
        { name: "nonce",     type: "uint256" },
        { name: "message",   type: "string"  }
      ]
    },
    domain: {
      name:    "ClobAuthDomain",
      version: "1",
      chainId: CHAIN_ID
    },
    primaryType: "ClobAuth",
    message: {
      address:   key.address.to_s,
      timestamp:,
      nonce:,
      message:   AUTH_MESSAGE
    }
  }

  digest = Eth::Eip712.hash(typed_data)
  Crypto.sign_digest(ENV.fetch("WALLET_PRIVATE_KEY"), digest)
end

begin
  key       = Eth::Key.new(priv: ENV.fetch("WALLET_PRIVATE_KEY"))
  timestamp = Time.now.to_i.to_s
  signature = build_l1_signature(key, timestamp)

  puts "[setup] Wallet : #{key.address}"
  puts "[setup] Sig    : #{signature[0..20]}..."

  conn = Faraday.new(url: CLOB_BASE_URL) { |f| f.adapter Faraday.default_adapter }

  headers = {
    "POLY_ADDRESS"   => key.address.to_s,
    "POLY_SIGNATURE" => signature,
    "POLY_TIMESTAMP" => timestamp,
    "POLY_NONCE"     => "0"
  }

  # Try derive (GET) first, then create (POST) as fallback
  resp = conn.get("/auth/derive-api-key")   { |r| r.headers.merge!(headers) }
  puts "[setup] GET /auth/derive-api-key → #{resp.status}: #{resp.body}"

  if resp.status != 200
    resp = conn.post("/auth/api-key") { |r| r.headers.merge!(headers) }
    puts "[setup] POST /auth/api-key    → #{resp.status}: #{resp.body}"
  end

  unless resp.status == 200
    warn "[setup] Both endpoints failed."
    exit 1
  end

  creds = JSON.parse(resp.body, symbolize_names: true)

  puts
  puts "Add these to your .env file:"
  puts "─" * 50
  puts "WALLET_PRIVATE_KEY=#{ENV['WALLET_PRIVATE_KEY']}"
  puts "POLY_API_KEY=#{creds[:apiKey]}"
  puts "POLY_API_SECRET=#{creds[:secret]}"
  puts "POLY_API_PASSPHRASE=#{creds[:passphrase]}"
  puts "─" * 50

rescue NameError => e
  warn "[setup] Eth::Eip712 not available: #{e.message}"
  exit 1
rescue KeyError
  warn "[setup] WALLET_PRIVATE_KEY not set in .env"
  exit 1
end
