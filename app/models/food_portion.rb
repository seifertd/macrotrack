# Scaling a `foods` row's per-100g nutrition into an entry of a given size (WP7).
#
# The sibling of MealPortion, which scales one *entry* onto another person's day. The
# split is that they start from different things: MealPortion has a plate someone already
# ate and a weight to scale against, while this has a density and a package.
#
# Two ways to say how much, because labels and people disagree about the unit. Grams are
# canonical — everything resolves to grams before it is scaled, and that is what lands on
# the entry. Servings are the *input* unit when the food knows what one weighs: a tub says
# "1/2 cup (115 g)", and "one serving" is what someone means when they eat it. Without a
# serving weight this behaves exactly as it did before, in grams alone.
#
# Deliberately the same arithmetic shape as MealPortion (one factor, applied to every
# figure) so the `portion` Stimulus controller drives both screens with no branching: the
# view hands it `reference_grams` and the figures at that reference, and its
# typed-grams ÷ reference factor is the same one computed here.
class FoodPortion
  include Portion

  # What per-100g means, and the fallback reference when a serving weight is unknown.
  PER = 100

  # Offered when the food knows its serving weight. Halves rather than the gram presets
  # because "half a tub" is the honest answer people actually give, and the fractions
  # only mean anything once there is a serving for them to be fractions *of*.
  SERVING_MULTIPLIERS = [ 0.5, 1.0, 1.5, 2.0 ].freeze

  # The fallback when it doesn't. A packaged serving is nearer 30–250g than the 360g
  # dinner plates the repeat picker deals in, so the presets start smaller.
  GRAM_PRESETS = [ 30, 50, 100, 150, 200 ].freeze

  FRACTIONS = { 0.5 => "½", 1.5 => "1½", 2.5 => "2½" }.freeze

  SCALED = { calories: :calories_per_100g, protein_g: :protein_per_100g,
             fat_g: :fat_per_100g, carbs_g: :carbs_per_100g }.freeze

  attr_reader :food

  # `servings` is ignored unless the food has a serving weight to multiply — there is
  # nothing to resolve it against otherwise, and silently treating it as grams would log
  # "2 servings" as two grams.
  def initialize(food, grams: nil, servings: nil)
    @food = food
    @given_grams = decimal(grams)
    @given_servings = decimal(servings)
  end

  def by_serving?
    food.serving_g.to_f.positive?
  end

  # One serving when the food has one, 100g otherwise. The view scales its preview from
  # the figures at this weight, so it is also what the chips are multiples of.
  def reference_grams
    by_serving? ? food.serving_g : BigDecimal(PER)
  end

  # Grams win when given, because they are the more specific answer: someone who typed a
  # number into the grams field meant that number.
  def grams
    return @given_grams if @given_grams
    return @given_servings * food.serving_g if @given_servings && by_serving?

    reference_grams
  end

  def servings
    return nil unless by_serving?

    grams / food.serving_g
  end

  def factor
    grams / PER
  end

  def scaled
    scale(grams)
  end

  # The figures for one reference portion, which is what the screen shows before anything
  # is typed and what its live preview scales from.
  def reference_scaled
    scale(reference_grams)
  end

  # Without calories there is nothing to log and nothing to show, so the screen sends the
  # scanner to manual entry instead of rendering a row of blanks.
  def loggable?
    food.calories_per_100g.present? && grams.positive?
  end

  # `[{ label:, multiplier: }]`, where the multiplier is relative to `reference_grams` —
  # exactly what the Stimulus controller multiplies by, so the view stays free of maths.
  def chips
    return GRAM_PRESETS.map { |g| { label: "#{g}g", multiplier: g.to_f / PER } } unless by_serving?

    SERVING_MULTIPLIERS.map { |m| { label: serving_label(m), multiplier: m } }
  end

  # `logged_as` mirrors MealPortion's naming for the same reason: this object already has
  # a `food`, and the entry's `source` is a different idea from either.
  #
  # One `Time.current`, read once and used twice: the meal has to be the one that clock
  # reading implies, not the one a second reading a microsecond later might. The meal is
  # read off the figures being written too, so it can never disagree with the row it
  # lands on.
  def attributes_for(user, logged_as: "barcode")
    at = Time.current
    figures = scaled

    figures.merge(
      user: user,
      food_id: food.id,
      quantity_grams: grams,
      source: logged_as,
      raw_input: food.name,
      meal_type: user.meal_type_at(at, calories: figures[:calories]),
      consumed_at: at
    )
  end

  # What was eaten, in the unit it was said in — "1½ servings" reads better than "172g"
  # when a serving is the thing that was chosen.
  def label
    return "#{format('%g', grams.to_f)}g" unless by_serving?

    serving_label(servings.to_f)
  end

  private
    def scale(weight)
      scale_from(food, weight / PER, SCALED)
    end

    def serving_label(count)
      # "½ servings" is not English. Anything up to a whole one is singular.
      unit = count <= 1 ? "serving" : "servings"

      "#{FRACTIONS[count] || format('%g', count)} #{unit}"
    end
end
