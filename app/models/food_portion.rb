# Scaling a `foods` row's per-100g nutrition into an entry of a given weight (WP7).
#
# The sibling of MealPortion, which scales one *entry* onto another person's day. The
# split is that they start from different things: MealPortion has a plate someone already
# ate and a weight to scale against, while this has a density and nothing else. A scanned
# yoghurt has no "what he had" to take half of — it has 100g figures and a tub.
#
# Deliberately the same arithmetic shape (one factor, applied to every figure) so the
# `portion` Stimulus controller drives both screens with no branching: pass 100 as the
# reference grams and the per-100g values as the base, and its grams/reference factor is
# exactly `factor` below.
class FoodPortion
  REFERENCE_GRAMS = 100

  # A packaged serving is nearer 30–250g than the 360g dinner plates the repeat picker
  # deals in, so the presets start smaller. Grams rather than multipliers because a label
  # states a weight and the scanner path always has one.
  PRESETS = [ 30, 50, 100, 150, 200 ].freeze

  SCALED = { calories: :calories_per_100g, protein_g: :protein_per_100g,
             fat_g: :fat_per_100g, carbs_g: :carbs_per_100g }.freeze

  attr_reader :food, :grams

  def initialize(food, grams: nil)
    @food = food
    @grams = presence_as_decimal(grams) || BigDecimal(REFERENCE_GRAMS)
  end

  def factor
    return BigDecimal(0) unless grams.positive?

    grams / REFERENCE_GRAMS
  end

  def scaled
    SCALED.transform_values do |per_100g|
      value = food.public_send(per_100g)
      value.nil? ? nil : value * factor
    end
  end

  # Without calories there is nothing to log and nothing to show, so the screen sends the
  # scanner to manual entry instead of rendering a row of blanks.
  def loggable?
    food.calories_per_100g.present? && grams.positive?
  end

  # `logged_as` mirrors MealPortion's naming for the same reason: this object already has
  # a `food`, and the entry's `source` is a different idea from either.
  def attributes_for(user, logged_as: "barcode")
    scaled.merge(
      user: user,
      food_id: food.id,
      quantity_grams: grams,
      source: logged_as,
      raw_input: food.name,
      consumed_at: Time.current
    )
  end

  def log_for!(user, logged_as: "barcode")
    user.meal_entries.create!(attributes_for(user, logged_as: logged_as).except(:user))
  end

  def label
    "#{format('%g', grams.to_f)}g"
  end

  private
    def presence_as_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
