module Foods
  # Barcode → nutrition, from the OpenFoodFacts database (WP7, design §6 path 1).
  #
  # The seam is the Faraday connection rather than a fake client object, unlike `Ai`.
  # The payload here is plain JSON, so swapping the *adapter* in tests keeps the real
  # parsing and mapping under test; a canned-object fake would skip exactly the code
  # most likely to be wrong.
  #
  # No API key and no account — that is the whole appeal. It is also community data, so
  # a row can be present but useless (a product with a name and no nutriments is common).
  # `find` returns nil for both "no such barcode" and "nothing usable on it", because the
  # caller does the same thing either way: offer manual entry.
  class OpenFoodFacts
    BASE_URL = "https://world.openfoodfacts.org"

    # v2 lets us name the fields, which keeps a ~50KB product document down to a few
    # hundred bytes. `nutriments` is one field containing all four numbers.
    FIELDS = %w[ code product_name product_name_en brands nutriments serving_size serving_quantity ].freeze

    # OpenFoodFacts asks that clients identify themselves and rate-limits anonymous
    # traffic harder. Two phones will never approach the limit, but being a good citizen
    # of a free community database costs one header.
    USER_AGENT = "MacroTrack/1.0 (household nutrition tracker; doug@dseifert.net)".freeze

    TIMEOUT = 5

    # A product row with no energy figure cannot be logged, so it counts as a miss.
    # kJ is the fallback because European products often carry only that.
    KJ_PER_KCAL = 4.184

    class << self
      attr_writer :connection

      def connection
        @connection ||= build_connection
      end

      def reset_connection!
        @connection = nil
      end

      def with_connection(replacement)
        previous = @connection
        @connection = replacement
        yield
      ensure
        @connection = previous
      end

      # Returns a persisted Food, or nil when the barcode is unknown or carries no
      # usable nutrition. Never raises on a network failure — a scan that cannot reach
      # the internet should fall back to manual entry, not 500.
      def find(barcode)
        barcode = normalize(barcode)
        return nil if barcode.blank?

        existing = Food.find_by(barcode: barcode)
        return existing if existing

        product = fetch(barcode) or return nil
        build(barcode, product)
      end

      # Ask upstream again for a row we already hold, and keep only the serving fields.
      # `find` deliberately never does this — a known barcode is answered from our own
      # table — so rows stored before `foods.serving_g` existed need an explicit nudge.
      # Returns the food when it gained a serving, nil when upstream has none either.
      def refresh_serving(food)
        product = fetch(normalize(food.barcode)) or return nil
        fields = serving(product)
        return nil if fields.blank?

        food.update!(**fields)
        food
      end

      # Digits only. Scanners and humans both produce stray whitespace, and a leading
      # zero is significant — UPC-A is EAN-13 with one — so this never casts to integer.
      #
      # The length bound is the same one the routes enforce, and deliberately so: this is
      # the single definition of "a barcode we accept", and anything it lets through has
      # to be safe to build a `scan/:barcode` URL from. EAN-8 is the short end, GTIN-14
      # the long one.
      LENGTH = (6..14)

      def normalize(barcode)
        digits = barcode.to_s.strip.gsub(/\D/, "")

        digits if LENGTH.cover?(digits.length)
      end

      private
        def build_connection
          Faraday.new(url: BASE_URL, headers: { "User-Agent" => USER_AGENT }) do |f|
            f.options.timeout = TIMEOUT
            f.options.open_timeout = TIMEOUT
          end
        end

        def fetch(barcode)
          response = connection.get("/api/v2/product/#{barcode}.json", fields: FIELDS.join(","))
          return nil unless response.success?

          body = JSON.parse(response.body)
          return nil unless body["status"].to_i == 1

          body["product"].presence
        rescue Faraday::Error, JSON::ParserError => e
          Rails.logger.warn("openfoodfacts lookup failed for #{barcode}: #{e.class}: #{e.message}")
          nil
        end

        def build(barcode, product)
          nutriments = product["nutriments"] || {}
          calories = calories_per_100g(nutriments)
          name = display_name(product)
          return nil if calories.nil? || name.blank?

          Food.create!(
            name: name,
            barcode: barcode,
            source: "openfoodfacts",
            calories_per_100g: calories,
            protein_per_100g: nutriment(nutriments, "proteins"),
            carbs_per_100g: nutriment(nutriments, "carbohydrates"),
            fat_per_100g: nutriment(nutriments, "fat"),
            **serving(product)
          )
        end

        # `serving_quantity` is the serving weight in grams; `serving_size` is the human
        # string it came from ("0.5 cup (115 g)"), which is worth keeping because it names
        # the unit the package actually uses. Plenty of products carry neither, and those
        # simply stay in grams.
        def serving(product)
          grams = Float(product["serving_quantity"]).round(2)
          return {} unless grams.positive?

          { serving_g: grams, serving_label: product["serving_size"].presence }
        rescue ArgumentError, TypeError
          {}
        end

        # Brand first because that is how a packaged product is recognised on a shelf and
        # in the repeat picker — "Oui black cherry yogurt", not "black cherry yogurt".
        # Multiple brands come back comma-separated; only the first is the maker.
        def display_name(product)
          name = product["product_name"].presence || product["product_name_en"].presence
          return nil if name.blank?

          brand = product["brands"].to_s.split(",").first&.strip.presence
          return name.strip if brand.blank? || name.downcase.include?(brand.downcase)

          "#{brand} #{name.strip}"
        end

        def calories_per_100g(nutriments)
          kcal = nutriment(nutriments, "energy-kcal")
          return kcal if kcal

          kj = nutriment(nutriments, "energy-kj") || nutriment(nutriments, "energy")
          kj && (kj / KJ_PER_KCAL).round(2)
        end

        # Absent and zero are different answers — a diet soda really is 0 kcal/100g —
        # so a missing key stays nil rather than becoming 0.
        def nutriment(nutriments, key)
          value = nutriments.to_h["#{key}_100g"]
          return nil if value.blank?

          Float(value).round(2)
        rescue ArgumentError, TypeError
          nil
        end
    end
  end
end
