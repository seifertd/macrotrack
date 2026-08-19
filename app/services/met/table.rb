module Met
  # Design §11: exercise burn is computed in Ruby, not estimated by the model. A MET
  # value is kcal per kilogram per hour, so the whole calculation is
  # `met * weight_kg * hours` — deterministic, free, and about as accurate as anything
  # short of a chest strap.
  #
  # The table is deliberately short. It covers what the two of us actually do; anything
  # unmatched falls back to a moderate-effort general value rather than refusing, because
  # a roughly-right number in the log beats a clarifying question about jazzercise.
  module Table
    # activity => [light, moderate, vigorous]
    VALUES = {
      "walking"       => [ 2.8,  3.5,  4.8 ],
      "hiking"        => [ 4.5,  6.0,  7.8 ],
      "running"       => [ 6.0,  9.8, 12.8 ],
      "cycling"       => [ 4.0,  8.0, 12.0 ],
      "swimming"      => [ 4.8,  6.0,  9.8 ],
      "rowing"        => [ 4.8,  7.0, 12.0 ],
      "elliptical"    => [ 4.6,  5.0,  9.0 ],
      "weightlifting" => [ 3.5,  5.0,  6.0 ],
      "yoga"          => [ 2.5,  3.0,  4.0 ],
      "pilates"       => [ 2.8,  3.0,  3.8 ],
      "gardening"     => [ 2.8,  3.8,  5.0 ],
      "housework"     => [ 2.3,  3.3,  4.0 ],
      "dancing"       => [ 3.0,  4.8,  7.8 ],
      "tennis"        => [ 5.0,  7.3,  8.0 ],
      "basketball"    => [ 4.5,  6.5,  8.0 ],
      "soccer"        => [ 5.0,  7.0, 10.0 ],
      "climbing"      => [ 5.8,  8.0, 11.0 ],
      "skiing"        => [ 4.3,  7.0,  9.0 ]
    }.freeze

    GENERAL = [ 3.0, 4.5, 6.5 ].freeze
    INTENSITIES = %w[ light moderate vigorous ].freeze

    # Until WP8 puts a weight field on screen there may be no weight on file, and a
    # burn of nil is worse than a burn computed from a plausible number.
    DEFAULT_WEIGHT_KG = 75

    def self.calories_for(activity:, intensity:, minutes:, weight_kg: nil)
      met = met_for(activity, intensity)
      hours = minutes.to_f / 60

      (met * (weight_kg || DEFAULT_WEIGHT_KG).to_f * hours).round(1)
    end

    def self.met_for(activity, intensity)
      row = VALUES.fetch(normalize(activity)) { VALUES[partial_match(activity)] || GENERAL }
      row[INTENSITIES.index(intensity.to_s) || 1]
    end

    def self.normalize(activity)
      activity.to_s.strip.downcase
    end

    # "trail running" and "lifting weights" should not fall through to the general
    # value just because they carry an adjective.
    def self.partial_match(activity)
      name = normalize(activity)
      VALUES.keys.find { |key| name.include?(key) || key.include?(name) && name.length > 3 }
    end
  end
end
