class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :last_meal_entry, class_name: "MealEntry", optional: true
  has_many :messages, dependent: :destroy
end
