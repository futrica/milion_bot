require "eth"
require "faraday"
require "json"
require "securerandom"
require "openssl"
require "base64"
require_relative "crypto"

# Polymarket CTF Exchange on Polygon mainnet
# Docs: https://docs.polymarket.com/developers/CLOB/orders/create-order
module OrderExecutor
  CHAIN_ID         = 137
  EXCHANGE_ADDRESS = "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E"
  CLOB_BASE_URL    = "https://clob.polymarket.com"
  USDC_DECIMALS    = 6   # USDC.e on Polygon has 6 decimal places

  # EIP-712 type strings (field order matters for the typehash)
  DOMAIN_TYPE_STRING = "EIP712Domain(string name,string version," \
                       "uint256 chainId,address verifyingContract)"

  ORDER_TYPE_STRING  = "Order(uint256 salt,address maker,address signer," \
                       "address taker,uint256 tokenId,uint256 makerAmount," \
                       "uint256 takerAmount,uint256 expiration,uint256 nonce," \
                       "uint256 feeRateBps,uint8 side,uint8 signatureType)"

  SIDE = { buy: 0, sell: 1 }.freeze

  class Executor
    def initialize
      @key            = Eth::Key.new(priv: ENV.fetch("WALLET_PRIVATE_KEY"))
      @api_key        = ENV.fetch("POLY_API_KEY")
      @api_secret     = ENV.fetch("POLY_API_SECRET")      # base64url-encoded
      @api_passphrase = ENV.fetch("POLY_API_PASSPHRASE")
      # For social login wallets: maker = main wallet, signer = operator key
      @proxy_address  = ENV["POLY_MAIN_ADDRESS"]

      @http = Faraday.new(url: CLOB_BASE_URL) do |f|
        f.request  :json
        f.response :raise_error
        f.adapter  Faraday.default_adapter
      end
    end

    # Place a GTC market order.
    # token_id  — decimal string from Polymarket (e.g. "123456")
    # side      — :buy or :sell
    # price     — YES price (e.g. 0.48)
    # size_usdc — USDC to spend (e.g. 10)
    def place_order(token_id:, side:, price:, size_usdc:)
      # CLOB requires: USDC amounts max 2 decimal places (→ multiple of 10_000 raw)
      #                token amounts max 4 decimal places (→ multiple of 100 raw)
      usdc_step  = 10_000   # 0.01 USDC in raw units
      token_step = 100      # 0.0001 tokens in raw units

      if side == :buy
        # BUY: maker = USDC, taker = tokens
        maker_amount = ((size_usdc.to_f * 10**USDC_DECIMALS) / usdc_step).floor * usdc_step
        taker_amount = ((maker_amount.to_f / price) / token_step).floor * token_step
      else
        # SELL: maker = tokens, taker = USDC
        maker_amount = ((size_usdc.to_f * 10**USDC_DECIMALS) / token_step).floor * token_step
        taker_amount = ((maker_amount.to_f * price) / usdc_step).floor * usdc_step
      end

      struct    = build_struct(token_id, SIDE[side], maker_amount, taker_amount)
      signature = eip712_sign(struct)
      body      = serialize(struct, signature)
      timestamp = Time.now.to_i.to_s

      puts "[OrderExecutor] Body: #{JSON.pretty_generate(body)}"
      resp   = @http.post("/order?geo_block_token=", body, l2_headers(timestamp, "POST", "/order", body.to_json))
      result = JSON.parse(resp.body, symbolize_names: true)

      puts "[OrderExecutor] #{side.upcase} $#{size_usdc} @ #{price} → " \
           "#{result[:orderID]} (#{result[:status]})"
      result
    rescue Faraday::Error => e
      warn "[OrderExecutor] Submission failed: #{e.message}"
      warn "[OrderExecutor] Response body: #{e.response&.dig(:body)}"
      nil
    end

    # Exposed for balance fetching in scanner
    def auth_headers(timestamp, method, path, body = "")
      l2_headers(timestamp, method, path, body)
    end

    private

    # -------------------------------------------------------------------------
    # Order struct
    # -------------------------------------------------------------------------
    def build_struct(token_id, side_int, maker_amount, taker_amount)
      # POLY_PROXY (signatureType=1): maker=main wallet, signer=operator key
      # EOA        (signatureType=0): maker=signer=operator key (no proxy)
      proxy         = @proxy_address && !@proxy_address.empty?
      maker_address = proxy ? @proxy_address : @key.address.to_s
      sig_type      = proxy ? 2 : 0   # 2 = POLY_GNOSIS_SAFE for social login proxy wallets

      {
        salt:          SecureRandom.random_number(10**12),  # keep within JS safe integer range
        maker:         maker_address,
        signer:        @key.address.to_s,
        taker:         "0x0000000000000000000000000000000000000000",
        tokenId:       token_id.to_s,
        makerAmount:   maker_amount,
        takerAmount:   taker_amount,
        expiration:    0,
        nonce:         0,
        feeRateBps:    1000,
        side:          side_int,
        signatureType: sig_type
      }
    end

    # -------------------------------------------------------------------------
    # EIP-712 signing
    # -------------------------------------------------------------------------
    def eip712_sign(order)
      domain_sep  = keccak256(abi_encode_domain)
      struct_hash = keccak256(abi_encode_order(order))
      digest      = keccak256("\x19\x01" + domain_sep + struct_hash)

      Crypto.sign_digest(ENV.fetch("WALLET_PRIVATE_KEY"), digest)
    end

    def abi_encode_domain
      keccak256(DOMAIN_TYPE_STRING) +
        keccak256("Polymarket CTF Exchange") +
        keccak256("1") +
        abi_uint256(CHAIN_ID) +
        abi_address(EXCHANGE_ADDRESS)
    end

    def abi_encode_order(o)
      keccak256(ORDER_TYPE_STRING) +
        abi_uint256(o[:salt])          +
        abi_address(o[:maker])         +
        abi_address(o[:signer])        +
        abi_address(o[:taker])         +
        abi_uint256(o[:tokenId].to_i)  +
        abi_uint256(o[:makerAmount])   +
        abi_uint256(o[:takerAmount])   +
        abi_uint256(o[:expiration])    +
        abi_uint256(o[:nonce])         +
        abi_uint256(o[:feeRateBps])    +
        abi_uint256(o[:side])          +
        abi_uint256(o[:signatureType])
    end

    # keccak256 via eth gem
    def keccak256(data)
      Eth::Util.keccak256(data)
    end

    # ABI-encode uint256 (arbitrary size) as 32-byte big-endian
    def abi_uint256(val)
      [val.to_i.to_s(16).rjust(64, "0")].pack("H*")
    end

    # ABI-encode address as 32-byte left-padded value
    def abi_address(addr)
      [addr.delete_prefix("0x").downcase.rjust(64, "0")].pack("H*")
    end

    # -------------------------------------------------------------------------
    # Request body — all numeric fields must be decimal strings
    # -------------------------------------------------------------------------
    def serialize(order, signature)
      {
        order: {
          salt:          order[:salt],
          maker:         order[:maker],
          signer:        order[:signer],
          taker:         order[:taker],
          tokenId:       order[:tokenId].to_s,
          makerAmount:   order[:makerAmount].to_s,
          takerAmount:   order[:takerAmount].to_s,
          expiration:    order[:expiration].to_s,
          nonce:         order[:nonce].to_s,
          feeRateBps:    order[:feeRateBps].to_s,
          side:          order[:side] == 0 ? "BUY" : "SELL",
          signatureType: order[:signatureType],
          signature:
        },
        owner:     @api_key,
        orderType: "FAK",
        deferExec: false,
        postOnly:  false
      }
    end

    # -------------------------------------------------------------------------
    # L2 HMAC-SHA256 authentication headers
    # secret is base64url-encoded; message = timestamp + method + path + body
    # -------------------------------------------------------------------------
    def l2_headers(timestamp, method, path, body = "")
      secret  = Base64.urlsafe_decode64(@api_secret)
      message = "#{timestamp}#{method}#{path}#{body}"
      sig     = Base64.urlsafe_encode64(
        OpenSSL::HMAC.digest("SHA256", secret, message)
      )

      {
        "POLY_ADDRESS"    => @key.address.to_s,
        "POLY_API_KEY"    => @api_key,
        "POLY_PASSPHRASE" => @api_passphrase,
        "POLY_SIGNATURE"  => sig,
        "POLY_TIMESTAMP"  => timestamp
      }
    end
  end
end
