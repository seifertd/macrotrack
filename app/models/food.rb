class Food < ApplicationRecord
  has_many :meal_entries, dependent: :nullify

  SOURCES = %w[ usda openfoodfacts ai_estimate user_custom ].freeze

  validates :name, presence: true
  validates :barcode, uniqueness: true, allow_nil: true

  # Trigram matching against this table is WP6; for now a food row is just a name
  # attached to an entry so the manual path has something to display.
  def self.find_or_create_by_name(name)
    return nil if name.blank?

    where("lower(name) = ?", name.strip.downcase).first ||
      create!(name: name.strip, source: "user_custom")
  end
end
