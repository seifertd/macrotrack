require "csv"

module Foods
  # Pulls selected rows out of the EasyFit Pro export into `foods`.
  #
  # Selected, not all of it. Every value here is divided by `serving_g` to reach the
  # per-100g shape `foods` wants, so a serving weight that was never real yields a
  # confidently wrong density with nothing on the row to flag it. Keeping a person in
  # the loop is the point, so nothing imports itself: rows arrive either named one at a
  # time by `import`, or marked `import=yes` in the CSV and pulled in by `import_selected`.
  # The column is Doug's own pass over the 123 rows, made in a spreadsheet — 56 yes.
  #
  # **The stated calories are the anchor, not the macros.** This reverses the original
  # call, which derived calories from 4P+4C+9F and discarded the export's own figure.
  # Doug crafted each serving to be the portion he actually eats and the calories he
  # believed it cost him; the macros came off a calculator and are the softer number.
  # Measured across all 123 rows the two mostly agree — median macro/stated ratio 1.004,
  # 104 rows within 10% — so this changes little in aggregate, but where they diverge
  # the stated figure is the one to keep. Magic Juice was stored at 81.13 kcal/100g
  # under the old rule and is 71.87 under this one, 12.9% lower.
  class EasyfitImport
    PATH = Rails.root.join("db/seeds/easyfit_foods.csv")

    # Pure fat is ~900 kcal/100g, so anything above it is arithmetic, not food. Below
    # ~15 and you are looking at a weight that swallowed the calories.
    PLAUSIBLE_DENSITY = (15.0..900.0)

    # Past this gap between the stated calories and what the macros add up to, the macro
    # split is not trustworthy. It does *not* impugn the calorie figure — that is taken
    # from the export directly — so this warns rather than raises. Blocking here would
    # withhold a good calorie number over a questionable protein/carb/fat breakdown, and
    # in a calorie tracker that is the wrong trade. 19 of 123 rows sit outside it.
    MACRO_GAP_TOLERANCE = 10.0

    class ImplausibleRow < StandardError; end
    class UnknownFood < StandardError; end
    class MissingSelection < StandardError; end

    Selection = Struct.new(:imported, :rejected, keyword_init: true) do
      def created = imported.select(&:created)
      def updated = imported.reject(&:created)
      def suspect = imported.select(&:macros_suspect?)
    end

    # A row the selected import refused. Bulk mode collects these instead of raising:
    # one placeholder serving weight should not withhold the other 55 rows.
    Rejected = Struct.new(:name, :message, keyword_init: true)

    Imported = Struct.new(:food, :serving_g, :stated_calories, :macro_calories, :created,
                          :drive_file_name, keyword_init: true) do
      # How far the export's macros drift from its own stated calories, as a percentage
      # of the stated figure. Surfaced per row so a big gap gets a second look.
      def calorie_gap_percent
        return 0.0 if stated_calories.to_f.zero?

        ((macro_calories - stated_calories).abs / stated_calories * 100).round(1)
      end

      # The calories are still right when this is true; only the split is doubtful.
      def macros_suspect?
        calorie_gap_percent > MACRO_GAP_TOLERANCE
      end
    end

    def self.rows(path: PATH)
      CSV.read(path, headers: true).map { |row| row.to_h.transform_keys { |key| key.to_s.downcase } }
    end

    def self.names(path: PATH)
      rows(path: path).map { |row| row["name"] }
    end

    # The rows Doug marked `import=yes`. Anything else — `no`, blank, a value the
    # spreadsheet invented — is not a yes, because the failure mode of guessing here is
    # importing a row nobody vetted.
    def self.selected(path: PATH)
      all = rows(path: path)
      raise MissingSelection, "#{path.basename} has no `import` column" unless all.first&.key?("import")

      all.select { |row| row["import"].to_s.strip.downcase == "yes" }
    end

    # Bulk counterpart to `import`. Collects rejections rather than raising them: a run
    # of 56 rows should not be withheld because one serving weight is a placeholder, and
    # the caller needs to see which rows landed as much as which did not. `import` still
    # raises, because a row named explicitly and skipped quietly would be a lie.
    #
    # `dry_run` runs the real thing and rolls it back, rather than simulating it. A
    # rehearsal that takes a different code path can only tell you about itself.
    def self.import_selected(path: PATH, dry_run: false)
      return collect_selected(path: path) unless dry_run

      result = nil
      Food.transaction do
        result = collect_selected(path: path)
        raise ActiveRecord::Rollback
      end
      result
    end

    def self.collect_selected(path: PATH)
      imported = []
      rejected = []

      selected(path: path).each do |row|
        imported << import_row(row)
      rescue ImplausibleRow => e
        rejected << Rejected.new(name: row["name"], message: e.message)
      end

      Selection.new(imported: imported, rejected: rejected)
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
      stated_calories = row["calories_kcal"].to_f
      macros = { protein: row["protein_g"].to_f, carbs: row["carbs_g"].to_f, fat: row["fat_g"].to_f }
      macro_calories = macros[:protein] * 4 + macros[:carbs] * 4 + macros[:fat] * 9

      raise ImplausibleRow, "#{row['name']}: serving_g is #{serving_g}" unless serving_g.positive?
      raise ImplausibleRow, "#{row['name']}: calories_kcal is #{stated_calories}" unless stated_calories.positive?

      # Checked against the stated calories, since those are what the row now claims.
      density = stated_calories / serving_g * 100
      unless PLAUSIBLE_DENSITY.cover?(density)
        raise ImplausibleRow,
          "#{row['name']}: #{density.round} kcal/100g is outside #{PLAUSIBLE_DENSITY} — " \
          "the serving weight is almost certainly a placeholder"
      end

      food = Food.find_or_initialize_by_name(row["name"])
      created = food.new_record?

      food.update!(
        source: "user_custom",
        calories_per_100g: per_100g(stated_calories, serving_g),
        serving_g: serving_g,
        serving_label: serving_label(row),
        **scaled_macros(macros, macro_calories, stated_calories, serving_g)
      )

      Imported.new(
        food: food, serving_g: serving_g, created: created,
        stated_calories: stated_calories, macro_calories: macro_calories,
        drive_file_name: row["drive_file_name"].presence
      )
    end

    # Storing the serving is what makes this import reversible. Every figure above is
    # `value / serving_g * 100`, so without the divisor the stated per-serving calories —
    # the number Doug actually crafted, and the one this importer now anchors on — could
    # not be recovered from the row afterwards. It also means the portion screen can offer
    # "1 serving" and land exactly on his number rather than near it.
    def self.serving_label(row)
      oz = row["serving_oz"].to_f
      return nil unless oz.positive?

      "#{format('%g', oz)} oz"
    end

    # Holds the export's protein:carb:fat ratio but rescales it so 4P+4C+9F lands on the
    # stated calories. Rounding to two places leaves the reconstructed total a hundredth
    # or so off the stored calorie figure; `calories_per_100g` is the authority, and the
    # macros are shaped to agree with it rather than the other way round.
    def self.scaled_macros(macros, macro_calories, stated_calories, serving_g)
      scale = stated_calories / macro_calories

      {
        protein_per_100g: per_100g(macros[:protein] * scale, serving_g),
        carbs_per_100g: per_100g(macros[:carbs] * scale, serving_g),
        fat_per_100g: per_100g(macros[:fat] * scale, serving_g)
      }
    end

    def self.per_100g(value, serving_g)
      (value / serving_g * 100).round(2)
    end
  end
end
