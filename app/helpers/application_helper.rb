module ApplicationHelper
  # Order matters: it's the order of the bar segments and of the legend under it.
  MACROS = [
    { key: :protein_g, label: "Protein", letter: "P", kcal_per_gram: 4, color: "bg-emerald-500" },
    { key: :fat_g,     label: "Fat",     letter: "F", kcal_per_gram: 9, color: "bg-amber-500" },
    { key: :carbs_g,   label: "Carbs",   letter: "C", kcal_per_gram: 4, color: "bg-sky-500" }
  ].freeze

  # A segment narrower than this can't hold its own label legibly, so it goes unlabelled
  # and the legend carries the number instead.
  LABEL_THRESHOLD = 12

  def grams(value)
    "#{value.to_f.round}g"
  end

  def calories(value)
    number_with_delimiter(value.to_f.round)
  end

  # Segments are sized by the calories each macro contributes, not by grams — that's what
  # a macro split conventionally means, and it's the only version that sums to the day's
  # energy. It also means 28g of fat is a wider segment than 52g of protein, which looks
  # like a bug unless the percentage is on screen. So each segment carries its own share.
  def macro_breakdown(totals)
    rows = MACROS.map do |macro|
      grams = totals[macro[:key]].to_f
      macro.merge(grams: grams, kcal: grams * macro[:kcal_per_gram])
    end

    total_kcal = rows.sum { |row| row[:kcal] }

    rows.map do |row|
      row.merge(share: total_kcal.zero? ? 0 : (row[:kcal] / total_kcal * 100).round)
    end
  end

  # The header's Add button is noise on the screen it leads to.
  def add_screen?
    controller_name == "meal_entries" && action_name == "new"
  end

  # Where a food's numbers came from, said in one phrase under its name. It matters
  # more now than it did when only the scanner showed it: a label is ground truth, and
  # an imported recipe is somebody's own arithmetic about their own cooking.
  def food_provenance(food)
    case food.source
    when "openfoodfacts" then "from the label"
    when "usda"          then "from the USDA tables"
    when "ai_estimate"   then "estimated"
    else "entered by hand"
    end
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
