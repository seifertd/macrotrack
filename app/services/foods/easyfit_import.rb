require "csv"

module Foods
  # Pulls selected rows out of the EasyFit Pro export into `foods`.
  #
  # Selected, not all of it. The export's serving weights are mostly not measurements:
  # 110 of 123 sit on a whole or half ounce and 48 are exactly 8 oz, which is the old
  # app's default rather than anything anyone weighed. Since `foods` is per-100g, every
  # value here is calories ÷ serving_g — so a defaulted weight yields a confidently wrong
  # density with nothing on the row to flag it. Importing by hand-picked name keeps a
  # person in the loop for the only judgement that matters: is this serving weight real?
  class EasyfitImport
    PATH = Rails.root.join("db/seeds/easyfit_foods.csv")

    # Pure fat is ~900 kcal/100g, so anything above it is arithmetic, not food. Below
    # ~15 and you are looking at a weight that swallowed the calories.
    PLAUSIBLE_DENSITY = (15.0..900.0)

    class ImplausibleRow < StandardError; end
    class UnknownFood < StandardError; end

    Imported = Struct.new(:food, :serving_g, :stated_calories, :macro_calories, :created, keyword_init: true) do
      # The export's stated calories and its macros disagree by up to 13%. Doug's call is
      # that the macros are the trustworthy half — they came off a recipe calculator,
      # where the stated figure went through a guessed serving fraction. Worth surfacing
      # per row so a big gap gets a second look rather than being averaged into the table.
      def calorie_gap_percent
        return 0.0 if stated_calories.to_f.zero?

        ((macro_calories - stated_calories).abs / stated_calories * 100).round(1)
      end
    end

    def self.rows(path: PATH)
      CSV.read(path, headers: true).map { |row| row.to_h.transform_keys(&:to_s) }
    end

    def self.names(path: PATH)
      rows(path: path).map { |row| row["name"] }
    end

    # Idempotent: re-running updates the existing row rather than duplicating it, so the
    # importer stays safe to run again after correcting a number in the CSV.
    def self.import(*wanted, path: PATH)
      wanted = wanted.flatten
      available = rows(path: path).index_by { |row| row["name"].to_s.strip.downcase }

      wanted.map do |name|
        row = available[name.to_s.strip.downcase] or
          raise(UnknownFood, "No row named #{name.inspect} in #{path.basename}")

        import_row(row)
      end
    end

    def self.import_row(row)
      serving_g = row["serving_g"].to_f
      macros = { protein: row["protein_g"].to_f, carbs: row["carbs_g"].to_f, fat: row["fat_g"].to_f }
      macro_calories = macros[:protein] * 4 + macros[:carbs] * 4 + macros[:fat] * 9

      raise ImplausibleRow, "#{row['name']}: serving_g is #{serving_g}" unless serving_g.positive?

      density = macro_calories / serving_g * 100
      unless PLAUSIBLE_DENSITY.cover?(density)
        raise ImplausibleRow,
          "#{row['name']}: #{density.round} kcal/100g is outside #{PLAUSIBLE_DENSITY} — " \
          "the serving weight is almost certainly a placeholder"
      end

      food = Food.find_or_initialize_by_name(row["name"])
      created = food.new_record?

      food.update!(
        source: "user_custom",
        calories_per_100g: per_100g(macro_calories, serving_g),
        protein_per_100g: per_100g(macros[:protein], serving_g),
        carbs_per_100g: per_100g(macros[:carbs], serving_g),
        fat_per_100g: per_100g(macros[:fat], serving_g)
      )

      Imported.new(
        food: food, serving_g: serving_g, created: created,
        stated_calories: row["calories_kcal"].to_f, macro_calories: macro_calories
      )
    end

    def self.per_100g(value, serving_g)
      (value / serving_g * 100).round(2)
    end
  end
end
