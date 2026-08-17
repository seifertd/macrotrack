class MealEntry < ApplicationRecord
  belongs_to :user
  belongs_to :food, optional: true

  # Set by the manual form and resolved to a Food row in the controller. Not a column:
  # the canonical name lives on foods, which is shared between both users.
  attr_accessor :food_name

  SOURCES = %w[ barcode matched photo voice text manual copied ].freeze
  MEAL_TYPES = %w[ breakfast lunch dinner snack ].freeze
  CONFIDENCES = %w[ high medium low ].freeze

  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :consumed_at, presence: true
  validates :meal_type, inclusion: { in: MEAL_TYPES }, allow_nil: true
  validates :confidence, inclusion: { in: CONFIDENCES }, allow_nil: true
  validates :calories, :protein_g, :fat_g, :carbs_g,
    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :chronological, -> { order(:consumed_at) }

  # Manual and barcode entries are read or typed, not inferred, so they don't get
  # hedged in the UI the way an AI estimate does (design §2).
  def estimated?
    %w[ voice text photo ].include?(source)
  end

  def display_name
    food&.name.presence || raw_input.presence || "Untitled entry"
  end
end
