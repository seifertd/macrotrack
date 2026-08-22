class Food < ApplicationRecord
  has_many :meal_entries, dependent: :nullify

  SOURCES = %w[ usda openfoodfacts ai_estimate user_custom ].freeze

  validates :name, presence: true
  validates :barcode, uniqueness: true, allow_nil: true

  # Only a row that knows its calories can be offered a portion — `FoodPortion` has
  # nothing to put on the screen without them, and most of this table is still names
  # the chat invented with no macros behind them.
  scope :loggable, -> { where.not(calories_per_100g: nil) }

  # A typed search is a different question from `Meals::Matcher`'s, and wants a
  # different rule. That reads a whole sentence and has to keep a correction from being
  # mistaken for a food, which is why it sits at 0.45 and only ever suggests. This reads
  # a query somebody deliberately typed into a search box; it has to survive a half-typed
  # word and a typo, and a wrong row here costs a glance.
  #
  # Two measures. `word_similarity` does most of the work, and does more of it than
  # expected: measured against the real names, it already handles the half-typed word
  # ("mag" scores 0.75 against *Magic Juice*, "juic" scores 1.00) and the fragment
  # starting mid-word ("inger Miso So" scores 0.85), because it scores the query against
  # the best-matching run of characters rather than the whole name.
  #
  # `ILIKE` is kept anyway, for two reasons. It is what covers a query too short for
  # trigrams to say anything about — a bare "m" scores 0.50 against *Magic Juice* and
  # would otherwise miss it. And it makes the promise unconditional: a run of characters
  # that really is in the name returns the row, whatever this threshold is tuned to next.
  # It is one more OR against the same GIN index, so it costs nothing to keep.
  #
  # 0.6, measured rather than guessed — ten real EasyFit names mistyped the way a phone
  # keyboard mistypes them, each scored against its own row and against the other 122.
  # The genuine pair scored 0.71 at worst and 1.00 at best; the strongest wrong row any
  # of those queries pulled up was 0.56 ("tofu stw" against *Tofu Fried Rice*), and the
  # next 0.54. So the gap is 0.56 to 0.71 and 0.6 sits in the middle of it. Note the
  # near-misses are near-misses, not nonsense: this threshold is trading a little recall
  # for a short list, which is the right trade on a phone.
  SEARCH_SIMILARITY = 0.6

  scope :named_like, ->(query) { where(name_match_sql("foods.name", query)) }

  # Ranking is a different question from matching, and needs both measures.
  #
  # `word_similarity(query, name)` asks whether the query turns up as a run of words
  # inside the name, which is what recall wants — but every name containing the query
  # scores 1.00 on it, so on its own it cannot tell "Portobello Sandwich" from "Chicken
  # soup with portobello mushrooms and teriyaki chicken", and the tie used to be broken
  # alphabetically, which put the soup first.
  #
  # `similarity(query, name)` asks how much of the name *is* the query, which is exactly
  # that distinction. It goes second rather than into a blended score so it breaks ties
  # without ever overriding recall: a long name that genuinely contains what you typed
  # still outranks a short one that only half matches.
  #
  # GREATEST across columns because an entry can match on its food's name or on the
  # transcript it was logged from, and COALESCE because raw_input is often NULL.
  def self.word_score_sql(query, *columns)
    score_sql("word_similarity", query, columns)
  end

  def self.whole_score_sql(query, *columns)
    score_sql("similarity", query, columns)
  end

  # Fully sanitised and returned as one fragment with no placeholders left in it. Passing
  # this to `order(sql, query)` instead would reintroduce the bug fixed in Meals::Matcher
  # on 2026-08-22: once the text is quoted into the string, a "?" in what the user typed
  # counts as a bind placeholder and the query raises before it is sent.
  def self.score_sql(measure, query, columns)
    terms = columns.map { |column| "#{measure}(:query, #{column})" }.join(", ")

    sanitize_sql_array([ "COALESCE(GREATEST(#{terms}), 0)", query: query ])
  end
  private_class_method :score_sql

  # The column is a literal from our own code, never user input; the query is bound.
  def self.name_match_sql(column, query)
    sanitize_sql_array([
      "(#{column} ILIKE :pattern OR word_similarity(:query, #{column}) >= #{SEARCH_SIMILARITY})",
      query: query, pattern: "%#{sanitize_sql_like(query.to_s)}%"
    ])
  end

  # The name the AI path calls. WP6b replaces the body with pg_trgm similarity scoped
  # to the household's recent entries — the point of the separate name is that the
  # tool handlers already call the matching entry point, so that change lands in one
  # method instead of every call site.
  def self.match_or_create(name)
    find_or_create_by_name(name)
  end

  # Trigram matching against this table is WP6; for now a food row is just a name
  # attached to an entry so the manual path has something to display.
  def self.find_or_create_by_name(name)
    return nil if name.blank?

    find_or_initialize_by_name(name).tap { |food| food.save! if food.new_record? }
  end

  # Unsaved, so a caller that is about to set nutrition can do it in one write.
  def self.find_or_initialize_by_name(name)
    return nil if name.blank?

    where("lower(name) = ?", name.strip.downcase).first ||
      new(name: name.strip, source: "user_custom")
  end
end
