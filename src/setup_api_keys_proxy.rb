#!/usr/bin/env ruby
# Derive Polymarket L2 API credentials using the PROXY WALLET address.
# For social login wallets: maker = proxy wallet, signer = embedded key.
# The CLOB verifies the signature via EIP-1271 on the proxy wallet contract.
#
require "eth"
require "faraday"
require "json"
require "dotenv/load"
require_relative "crypto"

CLOB_BASE_URL  = "https://clob.polymarket.com"
CHAIN_ID       = 137
AUTH_MESSAGE   = "This message attests that I control the given wallet"
PROXY_ADDRESS  = ENV.fetch("POLY_MAIN_ADDRESS")  # 0x6c506e7...

def build_l1_signature_for_proxy(key, proxy_addr, timestamp, nonce: 0)
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
      address:   key.address.to_s,   # operator key (signer), not proxy wallet
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
  signature = build_l1_signature_for_proxy(key, PROXY_ADDRESS, timestamp)

  puts "[setup] Operator key : #{key.address}"
  puts "[setup] Proxy wallet : #{PROXY_ADDRESS}"
  puts "[setup] Sig          : #{signature[0..20]}..."

  conn = Faraday.new(url: CLOB_BASE_URL) { |f| f.adapter Faraday.default_adapter }

  headers = {
    "POLY_ADDRESS"   => PROXY_ADDRESS,
    "POLY_SIGNATURE" => signature,
    "POLY_TIMESTAMP" => timestamp,
    "POLY_NONCE"     => "0"
  }

  resp = conn.get("/auth/derive-api-key") { |r| r.headers.merge!(headers) }
  puts "[setup] GET /auth/derive-api-key → #{resp.status}: #{resp.body}"

  if resp.status != 200
    resp = conn.post("/auth/api-key") { |r| r.headers.merge!(headers) }
    puts "[setup] POST /auth/api-key    → #{resp.status}: #{resp.body}"
  end

  unless resp.status == 200
    warn "[setup] Failed to get API key for proxy wallet."
    exit 1
  end

  creds = JSON.parse(resp.body, symbolize_names: true)

  puts
  puts "New keys for PROXY WALLET — add to .env:"
  puts "─" * 55
  puts "POLY_API_KEY=#{creds[:apiKey]}"
  puts "POLY_API_SECRET=#{creds[:secret]}"
  puts "POLY_API_PASSPHRASE=#{creds[:passphrase]}"
  puts "─" * 55

rescue => e
  warn "[setup] Error: #{e.message}"
  exit 1
end
