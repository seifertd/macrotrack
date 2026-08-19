class Food < ApplicationRecord
  has_many :meal_entries, dependent: :nullify

  SOURCES = %w[ usda openfoodfacts ai_estimate user_custom ].freeze

  validates :name, presence: true
  validates :barcode, uniqueness: true, allow_nil: true

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
