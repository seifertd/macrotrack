require "test_helper"

class Foods::CsvImportTest < ActiveSupport::TestCase
  # Unique per call: the suite runs in parallel above 50 tests, and a shared filename
  # has several processes writing the same fixture at once.
  def write(rows)
    path = Rails.root.join("tmp", "csv_import_test_#{SecureRandom.hex(6)}.csv")
    path.write(rows.join("\n") + "\n")
    @written = (@written || []) << path
    path
  end

  teardown { Array(@written).each { |path| File.delete(path) if File.exist?(path) } }

  HEADER = "name,basis,calories,protein_g,carbs_g,fat_g,serving_g,serving_label".freeze

  test "a per-100g row lands as written" do
    result = Foods::CsvImport.call(path: write([ HEADER, "Moussaka,100g,114.9,8.2,6.1,6.4,," ]))

    assert result.ok?, result.problems.map(&:to_s).inspect
    food = result.created.sole
    assert_equal "Moussaka", food.name
    assert_equal 114.9, food.calories_per_100g.to_f
    assert_equal 8.2, food.protein_per_100g.to_f
    assert_nil food.serving_g
    assert_equal "user_custom", food.source
  end

  test "a per-serving row is converted to per-100g and keeps its serving" do
    result = Foods::CsvImport.call(path: write([ HEADER, "Brie,serving,70,4,0,6,28.4,1 slice" ]))

    food = result.created.sole
    assert_equal 246.48, food.calories_per_100g.to_f
    assert_equal 14.08, food.protein_per_100g.to_f
    assert_equal 28.4, food.serving_g.to_f
    assert_equal "1 slice", food.serving_label
  end

  test "the stated per-serving figure survives the round trip" do
    food = Foods::CsvImport.call(path: write([ HEADER, "Magic Juice,serving,163,8,20,8,226.8,1 glass" ])).created.sole

    recovered = food.calories_per_100g.to_f * food.serving_g.to_f / 100
    assert_in_delta 163.0, recovered, 0.05
  end

  test "macros are optional and stay nil rather than becoming zero" do
    food = Foods::CsvImport.call(path: write([ HEADER, "Banana Rum Souffle,100g,127.7,,,,," ])).created.sole

    assert_equal 127.7, food.calories_per_100g.to_f
    assert_nil food.protein_per_100g, "a source that states only calories must not claim zero protein"
    assert_nil food.carbs_per_100g
    assert_nil food.fat_per_100g
  end

  test "basis=serving without a weight is refused" do
    result = Foods::CsvImport.call(path: write([ HEADER, "Nameless,serving,231,,,,,1 souffle" ]))

    assert_not result.ok?
    assert_match(/needs serving_g/, result.problems.map(&:to_s).join)
  end

  test "a serving label with no weight behind it is refused" do
    result = Foods::CsvImport.call(path: write([ HEADER, "Vague,100g,200,,,,,1 bowl" ]))

    assert_match(/no serving_g behind it/, result.problems.map(&:to_s).join)
  end

  test "an implausible density is refused rather than silently skipped" do
    result = Foods::CsvImport.call(path: write([ HEADER, "Placeholder,serving,90,6,0,7,3.5,1 slice" ]))

    assert_not result.ok?
    assert_match(/2571 kcal\/100g is outside/, result.problems.sole.to_s)
  end

  test "one bad row means nothing at all is imported" do
    path = write([ HEADER,
      "Good One,100g,120,5,10,4,,",
      "Bad One,serving,200,,,,,",
      "Good Two,100g,300,9,20,18,," ])

    assert_no_difference -> { Food.count } do
      result = Foods::CsvImport.call(path: path)
      assert_not result.ok?
      assert_empty result.imported
    end

    assert_nil Food.find_by("lower(name) = ?", "good one"),
      "a partial import leaves the caller unable to say what landed"
  end

  test "a name may appear only once" do
    result = Foods::CsvImport.call(path: write([ HEADER,
      "Moussaka,100g,114.9,8,6,6,,",
      "moussaka,100g,220,9,7,15,," ]))

    assert_not result.ok?
    assert_match(/duplicate of line 2/, result.problems.map(&:to_s).join)
  end

  test "problems name the line they came from" do
    result = Foods::CsvImport.call(path: write([ HEADER,
      "Fine,100g,120,5,10,4,,",
      "Broken,100g,not-a-number,,,,," ]))

    problem = result.problems.sole
    assert_equal 3, problem.line
    assert_equal "Broken", problem.name
    assert_match(/is not a number/, problem.message)
  end

  test "a missing required column is reported once, not per row" do
    result = Foods::CsvImport.call(path: write([ "name,calories", "Moussaka,114" ]))

    assert_equal 1, result.problems.size
    assert_match(/missing column\(s\): basis/, result.problems.sole.to_s)
  end

  test "re-importing updates rather than duplicating" do
    path = write([ HEADER, "Moussaka,100g,114.9,8,6,6,," ])
    first = Foods::CsvImport.call(path: path)
    assert_equal 1, first.created.size

    assert_no_difference -> { Food.count } do
      second = Foods::CsvImport.call(path: path)
      assert_empty second.created
      assert_equal first.created.sole, second.updated.sole
    end
  end

  test "an existing food keeps its identity and gains nutrition" do
    existing = Food.find_or_create_by_name("moussaka")
    assert_nil existing.calories_per_100g

    result = Foods::CsvImport.call(path: write([ HEADER, "Moussaka,100g,114.9,8,6,6,," ]))

    assert_equal existing, result.updated.sole, "matching is case-insensitive"
    assert_equal 114.9, existing.reload.calories_per_100g.to_f
  end

  test "a dry run reports what a real run would do and keeps none of it" do
    path = write([ HEADER, "Moussaka,100g,114.9,8,6,6,,", "Brie,serving,70,4,0,6,28.4,1 slice" ])

    rehearsal = nil
    assert_no_difference -> { Food.count } do
      rehearsal = Foods::CsvImport.call(path: path, dry_run: true)
    end
    assert rehearsal.ok?
    assert_equal 2, rehearsal.created.size

    real = Foods::CsvImport.call(path: path)
    assert_equal rehearsal.created.map(&:name).sort, real.created.map(&:name).sort,
      "the rehearsal did not leave rows behind"
  end

  test "an imported row is loggable" do
    Foods::CsvImport.call(path: write([ HEADER, "Moussaka,100g,114.9,8,6,6,," ]))

    assert_includes Food.loggable.pluck(:name), "Moussaka"
  end
end
