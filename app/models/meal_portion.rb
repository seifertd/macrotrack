# Scaling one person's entry onto another person's day.
#
# The reason this exists rather than a straight copy: Doug targets 2000 kcal and Raquel
# 1600, and they eat the same dinner in different amounts. A verbatim copy is wrong for
# whoever didn't cook, and "copy then edit" makes the person with the smaller portion do
# the extra work every single time.
class MealPortion
  include Portion

  # "Half of what he had" is often the honest answer, and nobody wants to weigh a bowl
  # to say it — so multipliers are offered even when the source carries real grams.
  MULTIPLIERS = [ 0.5, 1.0, 1.5, 2.0 ].freeze
  SCALED = %i[ calories protein_g fat_g carbs_g quantity_grams ].freeze

  attr_reader :source, :grams, :multiplier

  def initialize(source, grams: nil, multiplier: nil)
    @source = source
    @grams = decimal(grams)
    @multiplier = decimal(multiplier)
  end

  # Grams win when the source has a weight to scale against; otherwise the multiplier is
  # all there is. Both absent means "the same as they had".
  def factor
    if grams&.positive? && source.quantity_grams.to_f.positive?
      grams / source.quantity_grams
    elsif multiplier&.positive?
      multiplier
    else
      BigDecimal(1)
    end
  end

  # The weight the preview figures belong to. Nil when the source was never weighed, which
  # is exactly what makes `by_grams?` false and puts the screen into multiplier mode.
  def reference_grams
    source.quantity_grams
  end

  def scaled
    scale_from(source, factor, SCALED)
  end

  # What one un-portioned copy comes to — the source's own figures. This is what the screen
  # shows before anything is chosen, and what its live preview scales from.
  def reference_scaled
    scale_from(source, BigDecimal(1), SCALED)
  end

  # Shares rather than weights or servings: nobody weighs a bowl to say "half of what he
  # had". Shaped as FoodPortion's chips are — a label and a multiplier of the reference —
  # so one partial renders all three portion screens.
  def chips
    MULTIPLIERS.map { |multiplier| { label: "#{format('%g', multiplier)}×", multiplier: multiplier } }
  end

  # `logged_as` rather than `source:` on purpose — this object already has a `source`,
  # the entry being copied from, and one word meaning both things is how a String ends
  # up where a MealEntry was expected.
  def attributes_for(user, logged_as: "copied")
    scaled.merge(
      user: user,
      food_id: source.food_id,
      meal_type: source.meal_type,
      confidence: source.confidence,
      assumptions: assumptions,
      raw_input: source.raw_input,
      source: logged_as,
      consumed_at: Time.current
    )
  end

  # The source's assumptions describe the portion the *source* ate — "assumed a pub-sized
  # bowl" stops being true the moment it is halved. Rather than dropping them (they often
  # carry composition too, like "no cheese or sour cream") they get a note about what
  # changed, so the hedging on screen still matches the number next to it.
  def assumptions
    return source.assumptions if factor == 1

    [ "Portioned to #{label} of #{source.user.name}'s entry.", source.assumptions.presence ]
      .compact.join(" ")
  end

  def label
    return "#{format('%g', factor.to_f)}×" unless by_grams? && grams&.positive?

    "#{format('%g', grams.to_f)}g"
  end
end
