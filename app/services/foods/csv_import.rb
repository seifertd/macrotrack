require "csv"

module Foods
  # Imports a file of foods in the documented import format.
  #
  # One row is one food. Recipes do not appear here: ingredients, yields and cooking
  # methods are resolved into a single per-100g figure before the file is written, so
  # what arrives is already a food the app can put a portion of in front of someone.
  #
  # **The whole file is validated before anything is written.** A file with one bad row
  # imports nothing. That is deliberate — the caller is handing over a dataset they
  # believe is clean, and a partial import is worse than a rejected one because it
  # leaves them unable to say what actually landed.
  class CsvImport
    COLUMNS  = %w[ name basis calories protein_g carbs_g fat_g serving_g serving_label ].freeze
    REQUIRED = %w[ name basis calories ].freeze
    BASES    = %w[ serving 100g ].freeze

    # Same band the app applies everywhere else: pure fat is ~900 kcal/100g, so anything
    # above it is arithmetic rather than food, and below ~15 a weight has swallowed the
    # calories. Here it is a validation error rather than a silent skip, because a file
    # that contains one is not the clean dataset its author thinks it is.
    PLAUSIBLE_DENSITY = (15.0..900.0)

    Problem = Struct.new(:line, :name, :message, keyword_init: true) do
      def to_s
        "line #{line}#{name.present? ? " (#{name})" : ''}: #{message}"
      end
    end

    Row = Struct.new(:line, :name, :calories_per_100g, :protein_per_100g, :carbs_per_100g,
                     :fat_per_100g, :serving_g, :serving_label, keyword_init: true)

    Result = Struct.new(:created, :updated, :problems, keyword_init: true) do
      def ok? = problems.empty?
      def imported = created + updated
    end

    def self.call(path:, dry_run: false)
      new(path: path).call(dry_run: dry_run)
    end

    def initialize(path:)
      @path = path
    end

    # `dry_run` writes for real and rolls back, rather than simulating. A rehearsal that
    # takes a different code path can only tell you about itself.
    def call(dry_run: false)
      rows, problems = parse
      return Result.new(created: [], updated: [], problems: problems) if problems.any?

      created = []
      updated = []
      Food.transaction do
        rows.each do |row|
          food = Food.find_or_initialize_by_name(row.name)
          (food.new_record? ? created : updated) << food
          food.update!(
            source: "recipe",
            calories_per_100g: row.calories_per_100g,
            protein_per_100g: row.protein_per_100g,
            carbs_per_100g: row.carbs_per_100g,
            fat_per_100g: row.fat_per_100g,
            serving_g: row.serving_g,
            serving_label: row.serving_label
          )
        end
        raise ActiveRecord::Rollback if dry_run
      end

      Result.new(created: created, updated: updated, problems: [])
    end

    private

    attr_reader :path

    def parse
      table = CSV.read(path, headers: true)
      missing = REQUIRED - table.headers.map(&:to_s)
      return [ [], [ Problem.new(line: 1, message: "missing column(s): #{missing.join(', ')}") ] ] if missing.any?

      rows = []
      problems = []
      seen = {}

      table.each_with_index do |raw, index|
        line = index + 2 # header is line 1
        row, row_problems = build_row(raw.to_h.transform_keys { |k| k.to_s.downcase }, line)
        problems.concat(row_problems)
        next unless row

        # Two rows for one food is not a clean dataset — the importer cannot know which
        # figure the author meant, and upserting by name would silently keep the last.
        key = row.name.strip.downcase
        if seen.key?(key)
          problems << Problem.new(line: line, name: row.name,
            message: "duplicate of line #{seen[key]}; a name may appear only once")
        else
          seen[key] = line
          rows << row
        end
      end

      [ rows, problems ]
    end

    def build_row(attrs, line)
      problems = []
      name = attrs["name"].to_s.strip
      problems << Problem.new(line: line, message: "name is blank") if name.empty?

      basis = attrs["basis"].to_s.strip.downcase
      unless BASES.include?(basis)
        problems << Problem.new(line: line, name: name,
          message: "basis is #{attrs['basis'].inspect}, expected one of #{BASES.join(' or ')}")
      end

      numeric = {}
      %w[ calories serving_g protein_g carbs_g fat_g ].each do |column|
        text = attrs[column].to_s.strip
        next if text.empty?

        numeric[column] = Float(text, exception: false)
        next unless numeric[column].nil?

        problems << Problem.new(line: line, name: name, message: "#{column} #{text.inspect} is not a number")
      end

      calories = numeric["calories"]
      problems << Problem.new(line: line, name: name, message: "calories is required") if attrs["calories"].to_s.strip.empty?
      problems << Problem.new(line: line, name: name, message: "calories must be positive") if calories&.<=(0)

      serving_g = numeric["serving_g"]
      problems << Problem.new(line: line, name: name, message: "serving_g must be positive") if serving_g&.<=(0)

      label = attrs["serving_label"].to_s.strip.presence
      if label && serving_g.nil?
        problems << Problem.new(line: line, name: name,
          message: "serving_label #{label.inspect} has no serving_g behind it")
      end

      if basis == "serving" && serving_g.nil?
        problems << Problem.new(line: line, name: name,
          message: "basis=serving needs serving_g — without a weight the figures cannot reach per-100g")
      end

      macros = {}
      %w[ protein_g carbs_g fat_g ].each do |column|
        value = numeric[column]
        problems << Problem.new(line: line, name: name, message: "#{column} cannot be negative") if value&.negative?
        macros[column] = value
      end

      return [ nil, problems ] if problems.any?

      scale = basis == "serving" ? 100.0 / serving_g : 1.0
      density = (calories * scale).round(2)

      unless PLAUSIBLE_DENSITY.cover?(density)
        return [ nil, problems << Problem.new(line: line, name: name,
          message: "#{density.round} kcal/100g is outside #{PLAUSIBLE_DENSITY}") ]
      end

      [ Row.new(
        line: line, name: name, calories_per_100g: density,
        protein_per_100g: scaled(macros["protein_g"], scale),
        carbs_per_100g: scaled(macros["carbs_g"], scale),
        fat_per_100g: scaled(macros["fat_g"], scale),
        serving_g: serving_g, serving_label: label
      ), problems ]
    end

    # Blank stays nil rather than becoming zero. A source that states calories but no
    # macro breakdown is valid, and storing 0 would claim the food has no protein rather
    # than that nobody measured it.
    def scaled(value, scale)
      value && (value * scale).round(2)
    end
  end
end
