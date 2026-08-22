require "test_helper"

class Foods::EasyfitImportTest < ActiveSupport::TestCase
  test "derives per-100g values from the serving weight" do
    result = Foods::EasyfitImport.import("Magic Juice").sole
    food = result.food

    # 163 kcal in a 226.8g glass is 71.87 per 100g, and the macros are rescaled to agree.
    assert_equal 71.87, food.calories_per_100g.to_f
    assert_equal 3.12, food.protein_per_100g.to_f
    assert_equal 7.81, food.carbs_per_100g.to_f
    assert_equal 3.12, food.fat_per_100g.to_f
    assert_equal "user_custom", food.source
  end

  test "calories come from the stated figure, not the macros" do
    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert_equal 163.0, result.stated_calories
    assert_equal 184.0, result.macro_calories
    assert_equal 12.9, result.calorie_gap_percent

    assert_equal 71.87, result.food.calories_per_100g.to_f,
      "the serving Doug crafted is the anchor; 81.13 was the old macro-derived figure"
  end

  test "a row whose macros disagree with its calories is flagged, not rejected" do
    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert result.macros_suspect?, "12.9% is past the tolerance"
    assert_equal 71.87, result.food.calories_per_100g.to_f,
      "the calorie figure is still trustworthy — only the split is in doubt"
  end

  test "macros are rescaled to add up to the stated calories" do
    food = Foods::EasyfitImport.import("Magic Juice").sole.food

    reconstructed = food.protein_per_100g.to_f * 4 + food.carbs_per_100g.to_f * 4 + food.fat_per_100g.to_f * 9

    assert_in_delta food.calories_per_100g.to_f, reconstructed, 0.1,
      "the export's 8/20/8 split is kept in proportion but scaled down to 163 kcal"
  end

  test "a row whose macros already agree is imported untouched and unflagged" do
    result = Foods::EasyfitImport.import("Brie").sole

    assert_not result.macros_suspect?
    assert_equal 0.0, result.calorie_gap_percent
    assert_equal 246.48, result.food.calories_per_100g.to_f
    assert_equal 14.08, result.food.protein_per_100g.to_f
    assert_equal 21.13, result.food.fat_per_100g.to_f
  end

  test "keeps the serving, so the per-100g conversion is reversible" do
    food = Foods::EasyfitImport.import("Magic Juice").sole.food

    assert_equal 226.8, food.serving_g.to_f
    assert_equal "8 oz", food.serving_label

    recovered = food.calories_per_100g.to_f * food.serving_g.to_f / 100
    assert_in_delta 163.0, recovered, 0.05, "Doug's own per-serving figure comes back out"
  end

  test "re-running updates the existing row rather than duplicating it" do
    first = Foods::EasyfitImport.import("Magic Juice").sole
    assert first.created

    assert_no_difference -> { Food.count } do
      second = Foods::EasyfitImport.import("Magic Juice").sole
      assert_not second.created
      assert_equal first.food, second.food
    end
  end

  test "an existing food row keeps its identity and gains nutrition" do
    existing = Food.find_or_create_by_name("magic juice")
    assert_nil existing.calories_per_100g

    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert_equal existing, result.food, "matching is case-insensitive, so entries already logged stay attached"
    assert_equal 71.87, existing.reload.calories_per_100g.to_f
  end

  test "refuses a row whose density is physically impossible" do
    # 3.5g for 90 kcal is 2571 kcal/100g. The weight is a placeholder, and importing it
    # would put a confidently wrong density in front of every future estimate with
    # nothing on the row to flag it. Held against a fixture rather than the seed file:
    # the shipped dataset is hand-cleaned and is supposed to have no such row left.
    error = assert_raises Foods::EasyfitImport::ImplausibleRow do
      Foods::EasyfitImport.import("Placeholder Weight", path: file_fixture("easyfit_broken_rows.csv"))
    end

    assert_match(/placeholder/, error.message)
    assert_nil Food.find_by("lower(name) = ?", "placeholder weight")
  end

  test "refuses a row whose density is implausibly low" do
    assert_raises Foods::EasyfitImport::ImplausibleRow do
      Foods::EasyfitImport.import("Swallowed Calories", path: file_fixture("easyfit_broken_rows.csv"))
    end
  end

  test "names a row it cannot find rather than importing nothing quietly" do
    error = assert_raises Foods::EasyfitImport::UnknownFood do
      Foods::EasyfitImport.import("Magic Juice", "Nonexistent Smoothie")
    end

    assert_match(/Nonexistent Smoothie/, error.message)
  end

  test "selected picks up only the rows marked yes" do
    selected = Foods::EasyfitImport.selected

    assert_equal 56, selected.length
    assert_includes selected.map { |row| row["name"] }, "Magic Juice"
    assert_not_includes selected.map { |row| row["name"] }, "Acai Puree", "that row is marked no"
    assert_empty selected.reject { |row| row["import"] == "yes" }
  end

  test "selected says so when the column is missing rather than importing nothing" do
    path = file_fixture("easyfit_no_import_column.csv")

    error = assert_raises Foods::EasyfitImport::MissingSelection do
      Foods::EasyfitImport.selected(path: path)
    end

    assert_match(/import/, error.message)
  end

  test "anything that is not yes is not a yes" do
    path = file_fixture("easyfit_odd_flags.csv")

    assert_equal [ "Magic Juice" ], Foods::EasyfitImport.selected(path: path).map { |row| row["name"] },
      "blank, NO, and maybe are all withheld — guessing here imports a row nobody vetted"
  end

  test "every selected row in the shipped dataset imports" do
    result = Foods::EasyfitImport.import_selected

    assert_equal 56, result.imported.length
    assert_empty result.rejected,
      "the seed file is hand-cleaned; a rejection here means a row regressed, not that the gate is wrong"
    assert_includes result.imported.map { |r| r.food.name }, "Magic Juice"
  end

  test "a bulk run collects an implausible row instead of withholding the rest" do
    result = Foods::EasyfitImport.import_selected(path: file_fixture("easyfit_broken_rows.csv"))

    assert_equal [ "Magic Juice" ], result.imported.map { |r| r.food.name },
      "two bad rows must not cost the good one"
    assert_equal [ "Placeholder Weight", "Swallowed Calories" ], result.rejected.map(&:name)
  end

  test "a bulk run reports which rows have a doubtful macro split" do
    result = Foods::EasyfitImport.import_selected

    assert_includes result.suspect.map { |r| r.food.name }, "Magic Juice"
    assert_not_includes result.suspect.map { |r| r.food.name }, "Brie"
    assert result.suspect.length < result.imported.length, "the tolerance is not flagging everything"
  end

  test "a bulk run is idempotent" do
    first = Foods::EasyfitImport.import_selected
    assert_equal first.imported.length, first.created.length

    assert_no_difference -> { Food.count } do
      second = Foods::EasyfitImport.import_selected
      assert_empty second.created
      assert_equal first.imported.length, second.updated.length
    end
  end

  test "a dry run reports exactly what a real run would do, and keeps none of it" do
    rehearsal = nil

    assert_no_difference -> { Food.count } do
      rehearsal = Foods::EasyfitImport.import_selected(dry_run: true)
    end

    assert_equal 56, rehearsal.imported.length
    assert_empty rehearsal.rejected

    real = Foods::EasyfitImport.import_selected
    assert_equal rehearsal.imported.map { |r| r.food.name }.sort, real.imported.map { |r| r.food.name }.sort
    assert_equal rehearsal.imported.length, real.created.length, "the rehearsal did not leave rows behind"
  end

  test "carries the hand-matched Drive recipe through, for WP4.5 to reconcile against" do
    result = Foods::EasyfitImport.import("Moussaka").sole

    assert_equal "Moussaka.pdf", result.drive_file_name
    assert_nil Foods::EasyfitImport.import("Magic Juice").sole.drive_file_name,
      "no recipe in the folder corresponds to it"
  end

  test "the export is readable and every row has a name" do
    names = Foods::EasyfitImport.names

    assert_equal 123, names.length
    assert_empty names.select(&:blank?)
    assert_equal names.length, names.uniq.length
  end
end
