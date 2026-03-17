require "minitest/autorun"
require_relative "support/vcr_setup"
require_relative "../src/market_scanner"

CONDITION_ID = "0xabc123def456"
ENDPOINT     = "http://localhost:4000/analyze"

# Helper: use a VCR cassette for the duration of the block
def with_cassette(name, &block)
  VCR.use_cassette(name, &block)
end

# ---------------------------------------------------------------------------
# Connection & HTTP status codes
# ---------------------------------------------------------------------------
class TestConnection < Minitest::Test
  def test_successful_scan_hits_market_then_batch_books_endpoint
    with_cassette("market_btc") do
      scanner = MarketScanner::Scanner.new(condition_id: CONDITION_ID)
      payload = scanner.scan

      # GET /markets + POST /books — VCR raises if either is missing
      refute_nil payload
    end
  end

  def test_market_endpoint_5xx_raises_server_error
    with_cassette("market_500") do
      scanner = MarketScanner::Scanner.new(condition_id: CONDITION_ID)
      assert_raises(Faraday::ServerError) { scanner.scan }
    end
  end

  def test_market_endpoint_404_raises_resource_not_found
    with_cassette("market_404") do
      scanner = MarketScanner::Scanner.new(condition_id: CONDITION_ID)
      assert_raises(Faraday::ResourceNotFound) { scanner.scan }
    end
  end
end

# ---------------------------------------------------------------------------
# Payload structure & values
# ---------------------------------------------------------------------------
class TestPayload < Minitest::Test
  def setup
    @payload = with_cassette("market_btc") do
      MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
    end
  end

  def test_condition_id_matches
    assert_equal CONDITION_ID, @payload[:condition_id]
  end

  def test_description_is_present
    refute_nil  @payload[:description]
    refute_empty @payload[:description]
  end

  def test_timestamp_is_iso8601
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, @payload[:timestamp])
  end

  def test_two_outcomes_returned
    assert_equal 2, @payload[:market_price].length
  end

  def test_outcome_labels
    labels = @payload[:market_price].map { |o| o[:outcome] }
    assert_equal %w[YES NO], labels
  end

  def test_yes_buy_price
    yes = outcome("YES")
    assert_equal 0.73, yes[:buy_price]
  end

  def test_yes_sell_price
    yes = outcome("YES")
    assert_equal 0.71, yes[:sell_price]
  end

  def test_yes_spread_equals_ask_minus_bid
    yes = outcome("YES")
    assert_equal (yes[:buy_price] - yes[:sell_price]).round(4), yes[:spread]
  end

  def test_no_buy_price
    no = outcome("NO")
    assert_equal 0.29, no[:buy_price]
  end

  def test_total_liquidity_is_positive
    assert @payload[:total_liquidity] > 0
  end

  def test_total_liquidity_equals_sum_of_outcomes
    expected = @payload[:market_price].sum { |o| o[:liquidity] }.round(2)
    assert_equal expected, @payload[:total_liquidity]
  end

  private

  def outcome(label)
    @payload[:market_price].find { |o| o[:outcome] == label }
  end
end

# ---------------------------------------------------------------------------
# Nil safety — empty orderbooks must NOT crash the scanner
# ---------------------------------------------------------------------------
class TestNilSafety < Minitest::Test
  def test_empty_orderbook_does_not_raise
    with_cassette("orderbook_empty") do
      scanner = MarketScanner::Scanner.new(condition_id: CONDITION_ID)
      scanner.scan  # passes if no exception is raised
    end
  end

  def test_empty_orderbook_buy_price_is_nil
    with_cassette("orderbook_empty") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_nil payload[:market_price].first[:buy_price]
    end
  end

  def test_empty_orderbook_sell_price_is_nil
    with_cassette("orderbook_empty") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_nil payload[:market_price].first[:sell_price]
    end
  end

  def test_spread_is_nil_when_prices_are_nil
    # Ensures (nil - nil).round(4) is never called — would raise NoMethodError
    with_cassette("orderbook_empty") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_nil payload[:market_price].first[:spread]
    end
  end

  def test_liquidity_is_zero_when_orderbook_is_empty
    with_cassette("orderbook_empty") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_equal 0.0, payload[:market_price].first[:liquidity]
    end
  end

  def test_market_with_no_tokens_returns_empty_price_list
    with_cassette("market_no_tokens") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_equal [], payload[:market_price]
    end
  end

  def test_total_liquidity_is_zero_when_no_tokens
    with_cassette("market_no_tokens") do
      payload = MarketScanner::Scanner.new(condition_id: CONDITION_ID).scan
      assert_equal 0.0, payload[:total_liquidity]
    end
  end
end

# ---------------------------------------------------------------------------
# Analysis POST endpoint
# ---------------------------------------------------------------------------
class TestAnalysisPost < Minitest::Test
  def test_posts_payload_when_endpoint_is_set
    with_cassette("analysis_post_ok") do
      scanner = MarketScanner::Scanner.new(
        condition_id:      CONDITION_ID,
        analysis_endpoint: ENDPOINT
      )
      # VCR raises VCR::Errors::UnhandledHTTPRequestError if POST is never made
      scanner.scan
    end
  end

  def test_no_post_when_endpoint_is_nil
    with_cassette("market_btc") do
      scanner = MarketScanner::Scanner.new(condition_id: CONDITION_ID, analysis_endpoint: nil)
      # Cassette has no POST interaction — VCR would fail if POST were attempted
      scanner.scan
    end
  end

  def test_analysis_500_does_not_raise
    # The scanner must stay alive even if the downstream endpoint returns 500
    with_cassette("analysis_post_500") do
      scanner = MarketScanner::Scanner.new(
        condition_id:      CONDITION_ID,
        analysis_endpoint: ENDPOINT
      )
      scanner.scan  # passes if no exception is raised; warn to stderr is acceptable
    end
  end
end
