# Scaling one person's entry onto another person's day.
#
# The reason this exists rather than a straight copy: Doug targets 2000 kcal and Raquel
# 1600, and they eat the same dinner in different amounts. A verbatim copy is wrong for
# whoever didn't cook, and "copy then edit" makes the person with the smaller portion do
# the extra work every single time.
class MealPortion
  # "Half of what he had" is often the honest answer, and nobody wants to weigh a bowl
  # to say it — so multipliers are offered even when the source carries real grams.
  MULTIPLIERS = [ 0.5, 1.0, 1.5, 2.0 ].freeze
  SCALED = %i[ calories protein_g fat_g carbs_g quantity_grams ].freeze

  attr_reader :source, :grams, :multiplier

  def initialize(source, grams: nil, multiplier: nil)
    @source = source
    @grams = presence_as_decimal(grams)
    @multiplier = presence_as_decimal(multiplier)
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

  def by_grams?
    source.quantity_grams.to_f.positive?
  end

  def scaled
    SCALED.index_with do |attribute|
      value = source.public_send(attribute)
      value.nil? ? nil : value * factor
    end
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

  def log_for!(user, logged_as: "copied")
    user.meal_entries.create!(attributes_for(user, logged_as: logged_as).except(:user))
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

  private
    def presence_as_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
