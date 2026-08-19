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
