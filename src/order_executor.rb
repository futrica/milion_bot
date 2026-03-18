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
      maker_amount = (size_usdc.to_f * 10**USDC_DECIMALS).to_i

      # BUY:  spend maker_amount USDC, receive maker_amount/price tokens
      # SELL: spend maker_amount tokens, receive maker_amount*price USDC
      taker_amount = side == :buy ?
        (maker_amount.to_f / price).to_i :
        (maker_amount.to_f * price).to_i

      struct    = build_struct(token_id, SIDE[side], maker_amount, taker_amount)
      signature = eip712_sign(struct)
      body      = serialize(struct, signature)
      timestamp = Time.now.to_i.to_s

      resp   = @http.post("/order", body, l2_headers(timestamp, "POST", "/order", body.to_json))
      result = JSON.parse(resp.body, symbolize_names: true)

      puts "[OrderExecutor] #{side.upcase} $#{size_usdc} @ #{price} → " \
           "#{result[:orderID]} (#{result[:status]})"
      result
    rescue Faraday::Error => e
      warn "[OrderExecutor] Submission failed: #{e.message}"
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
      {
        salt:          SecureRandom.random_number(2**64),
        maker:         @key.address.to_s,
        signer:        @key.address.to_s,
        taker:         "0x0000000000000000000000000000000000000000",
        tokenId:       token_id.to_s,
        makerAmount:   maker_amount,
        takerAmount:   taker_amount,
        expiration:    0,
        nonce:         0,
        feeRateBps:    0,
        side:          side_int,
        signatureType: 0   # EOA
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
          salt:          order[:salt].to_s,
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
        orderType: "GTC"
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
