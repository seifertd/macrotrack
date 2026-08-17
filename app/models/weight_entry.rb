class WeightEntry < ApplicationRecord
  belongs_to :user

  validates :weight_kg, presence: true, numericality: { greater_than: 0 }
  validates :recorded_at, presence: true

  scope :chronological, -> { order(:recorded_at) }
end
