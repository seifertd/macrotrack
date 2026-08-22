namespace :foods do
  desc "Import named rows from the EasyFit export, e.g. rake 'foods:import_easyfit[Magic Juice,Spinach Omelette]'"
  task :import_easyfit, [ :names ] => :environment do |_task, args|
    names = args[:names].to_s.split(",").map(&:strip).reject(&:blank?)
    names += args.extras.map(&:strip).reject(&:blank?)

    if names.empty?
      puts "Pick rows by name. Available:"
      Foods::EasyfitImport.names.sort.each { |name| puts "  #{name}" }
      next
    end

    Foods::EasyfitImport.import(names).each do |result|
      food = result.food
      puts "#{result.created ? 'created' : 'updated'}  #{food.name}"
      puts "          #{food.calories_per_100g} kcal/100g  " \
           "P#{food.protein_per_100g} C#{food.carbs_per_100g} F#{food.fat_per_100g}"
      puts "          serving in the export: #{result.serving_g.round}g = #{result.stated_calories.round} kcal"

      if result.macros_suspect?
        puts "          note: the macros add up to #{result.macro_calories.round} kcal for that serving, " \
             "#{result.calorie_gap_percent}% off the stated #{result.stated_calories.round}. Calories are " \
             "from the stated figure; the P/C/F split is rescaled to match but is worth a look."
      end
    end
  rescue Foods::EasyfitImport::UnknownFood, Foods::EasyfitImport::ImplausibleRow => e
    abort "#{e.class.name.demodulize}: #{e.message}"
  end

  desc "Import every row marked import=yes in the EasyFit export; DRY_RUN=1 to rehearse"
  task import_easyfit_selected: :environment do
    dry_run = ENV["DRY_RUN"].present?
    result = Foods::EasyfitImport.import_selected(dry_run: dry_run)

    puts "#{dry_run ? 'DRY RUN — nothing was kept' : 'Imported'}: " \
         "#{result.created.size} created, #{result.updated.size} updated, #{result.rejected.size} rejected"
    puts

    result.imported.sort_by { |r| r.food.name }.each do |r|
      puts "#{r.created ? 'created' : 'updated'}  #{r.food.name}"
      puts "          #{r.food.calories_per_100g} kcal/100g  " \
           "P#{r.food.protein_per_100g} C#{r.food.carbs_per_100g} F#{r.food.fat_per_100g}"
      puts "          1 serving = #{r.serving_g.round}g = #{r.stated_calories.round} kcal"

      # Phase 0 is provisional for these. WP4.5 will cost the recipe from its ingredients
      # and land on this same row, so the pairing is recorded now, while the corpus is in
      # front of us, rather than fuzzy-matched later against a name that has drifted.
      puts "          reconciles with Drive: #{r.drive_file_name}" if r.drive_file_name

      if r.macros_suspect?
        puts "          note: macros add up to #{r.macro_calories.round} kcal, " \
             "#{r.calorie_gap_percent}% off the stated #{r.stated_calories.round}. Calories stand; " \
             "the P/C/F split is rescaled to match but is worth a look."
      end
    end

    if result.rejected.any?
      puts
      puts "Rejected — fix the row in db/seeds/easyfit_foods.csv and re-run:"
      result.rejected.each { |r| puts "  #{r.message}" }
    end

    if result.suspect.any?
      puts
      puts "#{result.suspect.size} row(s) with a macro split worth checking: " \
           "#{result.suspect.map { |r| r.food.name }.join(', ')}"
    end
  rescue Foods::EasyfitImport::MissingSelection => e
    abort "MissingSelection: #{e.message}"
  end

  desc "Import a foods CSV in the documented format, e.g. rake 'foods:import[db/seeds/foods.csv]'; DRY_RUN=1 to rehearse"
  task :import, [ :path ] => :environment do |_task, args|
    path = args[:path].presence or abort "Pass a path: rake 'foods:import[path/to/foods.csv]'"
    abort "No such file: #{path}" unless File.exist?(path)

    dry_run = ENV["DRY_RUN"].present?
    result = Foods::CsvImport.call(path: path, dry_run: dry_run)

    unless result.ok?
      puts "#{result.problems.size} problem(s); nothing was imported."
      result.problems.first(40).each { |problem| puts "  #{problem}" }
      puts "  ... and #{result.problems.size - 40} more" if result.problems.size > 40
      abort ""
    end

    puts "#{dry_run ? 'DRY RUN — nothing was kept' : 'Imported'}: " \
         "#{result.created.size} created, #{result.updated.size} updated"

    loggable = result.imported.count { |food| food.calories_per_100g.present? }
    portioned = result.imported.count { |food| food.serving_g.present? }
    puts "  #{loggable} can be logged; #{portioned} of those can offer a serving chip"
  end

  desc "Fill in serving weights for scanned foods imported before foods.serving_g existed"
  task backfill_servings: :environment do
    # `OpenFoodFacts.find` answers from our own table once a barcode is known, which is
    # the point of storing it — so a re-scan will never pick up serving data for a row
    # that predates the column. This asks upstream again, for those rows only.
    stale = Food.where.not(barcode: nil).where(serving_g: nil)
    puts "#{stale.count} scanned food(s) with no serving weight"

    stale.find_each do |food|
      fresh = Foods::OpenFoodFacts.refresh_serving(food)

      puts fresh ? "  #{food.name}: 1 serving = #{fresh.serving_g}g (#{fresh.serving_label})"
                 : "  #{food.name}: upstream states no serving — left in grams"
    end
  end
end
