# What FoodPortion and MealPortion do the same way.
#
# They start from different things — a density and a package versus a plate someone
# already ate — which is why they are two classes. But the arithmetic underneath is one
# shape: pick a reference, scale every figure by one factor against it, write one entry.
# That shape is here, so the two screens and the `portion` Stimulus controller can drive
# either one without asking which they have.
module Portion
  extend ActiveSupport::Concern

  # Whether the thing has a weight to scale against. Everything that does gets a grams
  # field; everything that doesn't gets the chips alone, backed by a multiplier. A food
  # always does (a serving weight, or 100g), an entry only if it was weighed.
  def by_grams?
    reference_grams.to_f.positive?
  end

  # Servings are a `foods` idea — a tub that says "1/2 cup (115 g)". An entry has no
  # serving to be a fraction of, so it answers no and the view skips that line.
  def by_serving?
    false
  end

  def log_for!(user, **options)
    user.meal_entries.create!(attributes_for(user, **options).except(:user))
  end

  private
    # `mapping` is attribute => reader, or a bare list when the two names agree.
    #
    # Nil-preserving on purpose: a food with no protein figure has to stay unknown. Coercing
    # it to zero would put "0g P" on screen, which is a claim we cannot make.
    def scale_from(subject, factor, mapping)
      mapping.to_h do |attribute, reader|
        value = subject.public_send(reader || attribute)

        [ attribute, value.nil? ? nil : value * factor ]
      end
    end

    def decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
end
