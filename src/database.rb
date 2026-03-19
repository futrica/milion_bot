require "sqlite3"
require "json"

DB_PATH = ENV.fetch("DB_PATH", "data/bot.db")

module Database
  def self.connection
    @connection ||= begin
      db = SQLite3::Database.new(DB_PATH)
      db.results_as_hash = true
      db.execute("PRAGMA journal_mode=WAL")
      db.execute("PRAGMA foreign_keys=ON")
      migrate(db)
      db
    end
  end

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------
  def self.migrate(db)
    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS scans (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        condition_id       TEXT    NOT NULL,
        market_question    TEXT,
        timestamp          TEXT    NOT NULL,
        end_date           TEXT,
        btc_price          REAL,
        yes_price          REAL,
        no_price           REAL,
        liquidity          REAL,
        claude_probability REAL,
        claude_edge        REAL,
        claude_confidence  REAL,
        recommendation     TEXT,
        reasoning          TEXT,
        action_taken       INTEGER NOT NULL DEFAULT 0,
        resolved           INTEGER NOT NULL DEFAULT 0,
        outcome            TEXT
      )
    SQL

    db.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS trades (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        condition_id    TEXT    NOT NULL,
        timestamp       TEXT    NOT NULL,
        recommendation  TEXT,
        probability     REAL,
        edge            REAL,
        confidence      REAL,
        yes_price       REAL,
        size_usdc       REAL,
        order_id        TEXT,
        order_status    TEXT,
        result          TEXT,
        pnl_usdc        REAL
      )
    SQL

    # Non-destructive migrations for existing DBs
    add_column(db, "scans",  "end_date",  "TEXT")
    add_column(db, "scans",  "strategy",  "TEXT")
    add_column(db, "scans",  "dry_run",   "INTEGER")
    add_column(db, "trades", "size_usdc",  "REAL")
    add_column(db, "trades", "pnl_usdc",   "REAL")
    add_column(db, "trades", "fill_price", "REAL")
    add_column(db, "trades", "shares",     "REAL")
    add_column(db, "trades", "strategy",   "TEXT")
    add_column(db, "trades", "dry_run",    "INTEGER")
  end

  def self.add_column(db, table, column, type)
    existing = db.execute("PRAGMA table_info(#{table})").map { |r| r["name"] }
    return if existing.include?(column)

    db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
  end

  # ---------------------------------------------------------------------------
  # Scans
  # ---------------------------------------------------------------------------
  def self.insert_scan(attrs)
    connection.execute(<<~SQL, attrs.values_at(*scan_columns))
      INSERT INTO scans
        (condition_id, market_question, timestamp, end_date, btc_price, yes_price, no_price,
         liquidity, claude_probability, claude_edge, claude_confidence,
         recommendation, reasoning, action_taken, resolved, outcome, strategy, dry_run)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    SQL
    connection.last_insert_row_id
  end

  def self.unresolved_scans
    connection.execute("SELECT * FROM scans WHERE resolved = 0")
  end

  def self.resolve_scan(id, outcome)
    connection.execute(
      "UPDATE scans SET resolved = 1, outcome = ? WHERE id = ?",
      [outcome, id]
    )
  end

  def self.recent_scans(limit: 20)
    connection.execute(
      "SELECT * FROM scans ORDER BY timestamp DESC LIMIT ?", [limit]
    )
  end

  def self.resolved_scans(limit: 50)
    connection.execute(
      "SELECT * FROM scans WHERE resolved = 1 ORDER BY timestamp DESC LIMIT ?", [limit]
    )
  end

  def self.scan_accuracy
    row = connection.get_first_row(<<~SQL)
      SELECT
        COUNT(*)                                          AS total,
        SUM(CASE WHEN outcome = 'correct' THEN 1 END)   AS correct
      FROM scans WHERE resolved = 1
    SQL
    total   = row["total"].to_i
    correct = row["correct"].to_i
    return nil if total.zero?

    { total:, correct:, accuracy: correct.to_f / total }
  end

  # ---------------------------------------------------------------------------
  # Trades
  # ---------------------------------------------------------------------------
  def self.insert_trade(attrs)
    connection.execute(<<~SQL, attrs.values_at(*trade_columns))
      INSERT INTO trades
        (condition_id, timestamp, recommendation, probability, edge,
         confidence, yes_price, size_usdc, order_id, order_status, result, pnl_usdc,
         fill_price, shares, strategy, dry_run)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    SQL
    connection.last_insert_row_id
  end

  def self.update_trade_result(condition_id, result, pnl_usdc)
    connection.execute(
      "UPDATE trades SET result = ?, pnl_usdc = ? WHERE condition_id = ? AND result IS NULL",
      [result, pnl_usdc, condition_id]
    )
  end

  def self.total_pnl
    row = connection.get_first_row("SELECT SUM(pnl_usdc) AS pnl FROM trades WHERE pnl_usdc IS NOT NULL")
    row["pnl"]
  end

  def self.recent_trades(limit: 20)
    connection.execute(
      "SELECT * FROM trades ORDER BY timestamp DESC LIMIT ?", [limit]
    )
  end

  def self.win_rate
    row = connection.get_first_row(<<~SQL)
      SELECT
        COUNT(*)                                        AS total,
        SUM(CASE WHEN result = 'win' THEN 1 END)       AS wins
      FROM trades WHERE result IS NOT NULL
    SQL
    total = row["total"].to_i
    wins  = row["wins"].to_i
    return nil if total.zero?

    { total:, wins:, rate: wins.to_f / total }
  end

  # ---------------------------------------------------------------------------
  # Backup — dumps the full DB as plain SQL text (commit this, not the .db)
  # ---------------------------------------------------------------------------
  def self.dump(path = "data/backup.sql")
    lines = ["-- milion_bot database dump #{Time.now.utc.iso8601}", ""]
    connection.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rootpage") do |row|
      lines << row["sql"] + ";"
    end
    lines << ""
    ["scans", "trades"].each do |table|
      connection.execute("SELECT * FROM #{table}") do |row|
        vals = row.values_at(*row.keys.grep(String)).map { |v|
          v.nil? ? "NULL" : "'#{v.to_s.gsub("'", "''")}'"
        }.join(", ")
        lines << "INSERT INTO #{table} VALUES (#{vals});"
      end
    end
    File.write(path, lines.join("\n") + "\n")
  end

  private

  def self.scan_columns
    %i[condition_id market_question timestamp end_date btc_price yes_price no_price
       liquidity claude_probability claude_edge claude_confidence
       recommendation reasoning action_taken resolved outcome strategy dry_run]
  end

  def self.trade_columns
    %i[condition_id timestamp recommendation probability edge
       confidence yes_price size_usdc order_id order_status result pnl_usdc
       fill_price shares strategy dry_run]
  end
end
