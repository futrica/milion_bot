require "rbsecp256k1"

# Low-level secp256k1 signing for EIP-712.
# eth gem's Key#sign adds a personal-sign prefix — wrong for EIP-712.
# We sign the raw 32-byte digest directly using rbsecp256k1.
module Crypto
  # Returns Ethereum-compatible hex signature: 0x + r(32) + s(32) + v(1) = 65 bytes
  def self.sign_digest(private_key_hex, digest_bytes)
    ctx      = Secp256k1::Context.create
    priv_key = [private_key_hex.delete_prefix("0x")].pack("H*")
    key_pair = ctx.key_pair_from_private_key(priv_key)
    sig      = ctx.sign_recoverable(digest_bytes, key_pair)

    compact, recovery_id = sig.compact
    v = 27 + recovery_id

    "0x" + compact.unpack1("H*") + v.to_s(16).rjust(2, "0")
  end
end
