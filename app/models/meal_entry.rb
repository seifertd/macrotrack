class MealEntry < ApplicationRecord
  include ScoredByName

  belongs_to :user
  belongs_to :food, optional: true


  # Set by the manual form and resolved to a Food row in the controller. Not a column:
  # the canonical name lives on foods, which is shared between both users.
  attr_accessor :food_name

  SOURCES = %w[ barcode matched photo voice text manual copied ].freeze
  MEAL_TYPES = %w[ breakfast lunch dinner snack ].freeze
  CONFIDENCES = %w[ high medium low ].freeze

  # Which meal something reads as, for the two paths that log a food without asking —
  # the picker's food rows and the scanner, both of which go through FoodPortion.
  # Repeating an eaten meal has a real answer to copy (MealPortion takes the source's)
  # and the chat requires one in its tool call, so this is the only place left where the
  # alternative is no meal at all.
  #
  # Size is asked first, because it is the better evidence. 28g of havarti at six in the
  # morning is not breakfast however early it is — it is a snack that happens to be
  # early, and the clock alone would call it a meal. Only a portion big enough to be a
  # meal gets to be one, and then the hour says which.
  #
  # Both halves are guesses, and cheap ones: they are visible on the entry the moment it
  # is written and editable from the screen it is written to. The thing they replace —
  # a blank — is not more honest, just emptier.
  SNACK_CEILING = 300

  MEAL_TYPE_HOURS = { "breakfast" => 5..10, "lunch" => 11..15, "dinner" => 16..20 }.freeze

  def self.infer_meal_type(hour:, calories: nil)
    return "snack" if calories && calories < SNACK_CEILING

    MEAL_TYPE_HOURS.find { |_, hours| hours.cover?(hour) }&.first || "snack"
  end

  # The picker, the scanner and the repeat screen all write entries with no meal type —
  # none of them asks, because none of them has to. The edit form renders those as its
  # blank option, which posts back "" rather than nil, and "" is not in the list. So the
  # one screen for fixing an entry refused to save any entry logged from a food until a
  # meal was chosen, on a field that is optional everywhere else.
  normalizes :meal_type, with: ->(value) { value.presence }

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :consumed_at, presence: true
  validates :meal_type, inclusion: { in: MEAL_TYPES }, allow_nil: true
  validates :confidence, inclusion: { in: CONFIDENCES }, allow_nil: true
  validates :calories, :protein_g, :fat_g, :carbs_g,
    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :chronological, -> { order(:consumed_at) }
  # The day page reads newest first: the thing you just logged is the thing you want
  # to check, and it should be at the top rather than at the bottom of the day.
  scope :reverse_chronological, -> { order(consumed_at: :desc, id: :desc) }

  # What the household has eaten lately, newest first — the pool the repeat picker draws
  # from. Scoped to the household rather than the user because the whole point is picking
  # off the other person's plate.
  # `preload`, not `includes`. The search path chains `named_like` onto this, whose string
  # `where` mentions foods.name; that turned the `includes` into an eager_load, which joined
  # `foods` a second time alongside named_like's own LEFT JOIN and pulled every `users`
  # column — `password_digest`, a bcrypt hash — into the web process once per result row.
  # Preloading keeps the two associations in their own queries, so the only join here is
  # the one the filter actually needs.
  def self.recent_in_household(household, since: 30.days.ago, limit: 100)
    joins(:user).where(users: { household_id: household.id })
      .where(consumed_at: since..)
      .order(consumed_at: :desc).limit(limit)
      .preload(:food, :user)
  end

  # The same typed search as `Food.named_like`, against what the household has actually
  # eaten. `raw_input` is matched as well as the food's name because `display_name` falls
  # back to it — a row you can read on the day page is a row you should be able to find —
  # and the join is left, or entries with no food row would drop out of their own search.
  scope :named_like, ->(query) {
    left_joins(:food).where(
      "#{Food.name_match_sql('foods.name', query)} OR #{Food.name_match_sql('meal_entries.raw_input', query)}"
    )
  }

  # raw_input as well as the food's name, because display_name falls back to it.
  def self.search_columns = [ "foods.name", "meal_entries.raw_input" ]

  # Deduplicated by food, so a dinner eaten four times in a fortnight occupies one row of
  # the picker instead of four. Done in Ruby rather than SQL: entries without a food row
  # fall back to their display name, and DISTINCT ON can't express that.
  def self.distinct_by_food(entries)
    entries.uniq { |entry| entry.food_id || entry.display_name.downcase }
  end



  # Manual and barcode entries are read or typed, not inferred, so they don't get
  # hedged in the UI the way an AI estimate does (design §2).
  def estimated?
    %w[ voice text photo ].include?(source)
  end

  def display_name
    food&.name.presence || raw_input.presence || "Untitled entry"
  end
end
