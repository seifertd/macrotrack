namespace :foods do
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
