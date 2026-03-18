#!/usr/bin/env ruby
# One-time script to derive Polymarket L2 API credentials from your wallet.
# Run once, then copy the output to your .env file.
#
# Usage:
#   WALLET_PRIVATE_KEY=0x... ruby src/setup_api_keys.rb
#
require "eth"
require "faraday"
require "json"
require "dotenv/load"

CLOB_BASE_URL = "https://clob.polymarket.com"
CHAIN_ID      = 137

# EIP-712 domain for CLOB authentication (different from order signing domain)
AUTH_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId)"
AUTH_STRUCT_TYPE = "ClobAuth(address address,string timestamp,uint256 nonce,string message)"
AUTH_MESSAGE     = "This message attests that I control the given wallet"

def keccak256(data) = Eth::Util.keccak256(data)

def abi_uint256(val) = [val.to_i.to_s(16).rjust(64, "0")].pack("H*")
def abi_address(addr) = [addr.delete_prefix("0x").downcase.rjust(64, "0")].pack("H*")

def build_l1_signature(key, timestamp, nonce: 0)
  domain_sep = keccak256(
    keccak256(AUTH_DOMAIN_TYPE) +
    keccak256("ClobAuthDomain") +
    keccak256("1") +
    abi_uint256(CHAIN_ID)
  )

  struct_hash = keccak256(
    keccak256(AUTH_STRUCT_TYPE) +
    abi_address(key.address.to_s) +
    keccak256(timestamp) +
    abi_uint256(nonce) +
    keccak256(AUTH_MESSAGE)
  )

  digest    = keccak256("\x19\x01" + domain_sep + struct_hash)
  sig_bytes = key.sign(digest)
  "0x" + sig_bytes.unpack1("H*")
end

begin
  key       = Eth::Key.new(priv: ENV.fetch("WALLET_PRIVATE_KEY"))
  timestamp = Time.now.to_i.to_s
  signature = build_l1_signature(key, timestamp)

  puts "[setup] Wallet address : #{key.address}"
  puts "[setup] Calling GET /auth/derive-api-key ..."

  conn = Faraday.new(url: CLOB_BASE_URL) do |f|
    f.response :raise_error
    f.adapter  Faraday.default_adapter
  end

  resp = conn.get("/auth/derive-api-key") do |req|
    req.headers["POLY_ADDRESS"]   = key.address.to_s
    req.headers["POLY_SIGNATURE"] = signature
    req.headers["POLY_TIMESTAMP"] = timestamp
    req.headers["POLY_NONCE"]     = "0"
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
rescue Faraday::Error => e
  warn "[setup] Request failed: #{e.message}"
  exit 1
rescue KeyError
  warn "[setup] Set WALLET_PRIVATE_KEY in your environment first."
  exit 1
end
