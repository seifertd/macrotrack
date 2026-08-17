class ExerciseEntry < ApplicationRecord
  belongs_to :user

  validates :performed_at, presence: true

  scope :chronological, -> { order(:performed_at) }
end
