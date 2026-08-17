class User < ApplicationRecord
  has_secure_password
  belongs_to :household
  has_many :sessions, dependent: :destroy
  has_many :meal_entries, dependent: :destroy
  has_many :weight_entries, dependent: :destroy
  has_many :exercise_entries, dependent: :destroy
  has_one :conversation, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true
  validates :timezone, presence: true, inclusion: { in: ActiveSupport::TimeZone::MAPPING.values }

  TOTAL_COLUMNS = %i[ calories protein_g fat_g carbs_g ].freeze

  # Everyone else who shares this kitchen — the targets for "also log this for them".
  # Returns a collection rather than a single user on purpose: nothing here assumes the
  # household is exactly two people.
  def household_members
    household.users.excluding(self).order(:name)
  end

  def household_member_named(name)
    household_members.find_by("lower(name) = ?", name.to_s.strip.downcase)
  end

  # Which local day a UTC timestamp belongs to. For a calorie tracker "what day was
  # this" is the product, so every rollup goes through here rather than Date.current.
  def local_date(at = Time.current)
    at.in_time_zone(timezone).to_date
  end

  def local_today
    local_date
  end

  # A local calendar day expressed as a UTC-comparable range, so the SQL boundary
  # matches the boundary the user actually experiences.
  def day_range(date)
    Time.use_zone(timezone) { date.all_day }
  end

  def entries_on(date)
    meal_entries.where(consumed_at: day_range(date))
  end

  # Accepts a Time (resolved to its local date) or a Date. Returns a hash of BigDecimals
  # so callers can round for display; §16's tool handlers hand this straight to the model.
  def day_totals(at = Time.current)
    date = at.acts_like?(:time) ? local_date(at) : at.to_date

    sums = entries_on(date).pick(
      *TOTAL_COLUMNS.map { |column| Arel.sql("COALESCE(SUM(#{column}), 0)") }
    )

    TOTAL_COLUMNS.zip(Array(sums)).to_h
  end

  def calories_remaining(at = Time.current)
    daily_calorie_target.to_i - day_totals(at)[:calories].to_i
  end
end
