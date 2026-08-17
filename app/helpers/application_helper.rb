module ApplicationHelper
  CALORIES_PER_GRAM = { protein_g: 4, fat_g: 9, carbs_g: 4 }.freeze

  def grams(value)
    "#{value.to_f.round}g"
  end

  def calories(value)
    number_with_delimiter(value.to_f.round)
  end

  # Macro bars are sized by the calories each macro contributes rather than by grams,
  # so the widths add up to the day's total and the bar reads as composition.
  def macro_shares(totals)
    contributions = CALORIES_PER_GRAM.to_h do |column, kcal_per_gram|
      [ column, totals[column].to_f * kcal_per_gram ]
    end

    sum = contributions.values.sum
    return CALORIES_PER_GRAM.keys.index_with { 0 } if sum.zero?

    contributions.transform_values { |value| (value / sum * 100).round }
  end

  def confidence_badge_classes(confidence)
    case confidence
    when "low"    then "bg-amber-100 text-amber-800"
    when "medium" then "bg-sky-100 text-sky-800"
    when "high"   then "bg-emerald-100 text-emerald-800"
    else "bg-slate-100 text-slate-600"
    end
  end
end
