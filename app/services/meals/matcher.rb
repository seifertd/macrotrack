module Meals
  # Design §7 path 1: before anything is estimated, check whether this household has
  # eaten it before. Trigram similarity over the last 90 days of entries, then over the
  # global foods table.
  #
  # Scoring takes the best of three measures, and the shape of that matters. Plain
  # `similarity` compares whole strings, which collapses when a short food name is
  # buried in a sentence — "Magic Juice" against "I had a glass of magic juice" scores
  # 0.41. `word_similarity(name, text)` asks how well the name matches some run of words
  # inside the sentence, which is the actual question, and scores the same pair 1.00.
  # The reverse direction rescues the opposite case, where a long stored name is only
  # partly named ("leftover ikea meatballs" against the full plate). Taking the greatest
  # of the three separates real matches (0.45 and up in testing) from unrelated food
  # (0.12 and below) with room to spare.
  class Matcher
    WINDOW = 90.days

    # 0.45, and it is a tighter fit than it looks. Follow-ups in a conversation score
    # alarmingly well against food names — "make that double chicken" hits 0.40 against
    # *chicken burrito bowl*, "the pasta was bigger than that" hits 0.35 — because
    # trigram similarity measures spelling, and a correction is made of the same words
    # as the thing it corrects. The gap between the highest follow-up (0.40) and the
    # weakest genuine match (0.45) is the entire safety margin, which is why a hit
    # offers a suggestion instead of writing a row.
    THRESHOLD = 0.45

    # A lower bar for what gets mentioned to the model. Wrong guesses here cost a line
    # in a prompt, not an entry in the log.
    HINT_THRESHOLD = 0.30
    HINT_LIMIT = 5

    Match = Struct.new(:entry, :food, :score, keyword_init: true) do
      def name = (entry&.food || food)&.name
      def entry? = entry.present?
    end

    def initialize(user, text)
      @user = user
      @text = text.to_s.strip
    end

    # The best previous meal, or nil. Only entries: a match is worth offering when there
    # is a portion attached to it, and a bare foods row has no portion to offer.
    def best_entry
      return nil if @text.blank?

      row = scored_entries.first or return nil
      Match.new(entry: row, score: row.match_score.to_f)
    end

    # Everything worth telling the model about, entries and foods alike, for the turns
    # that do reach the API. This is what stops "magic juice" being read as a typo for
    # mango juice: the model is shown the food by name before it is asked to guess.
    def hints
      return [] if @text.blank?

      (scored_entries(HINT_THRESHOLD).map { |entry| Match.new(entry: entry, score: entry.match_score.to_f) } +
        scored_foods(HINT_THRESHOLD).map { |food| Match.new(food: food, score: food.match_score.to_f) })
        .uniq { |match| match.name&.downcase }
        .sort_by { |match| -match.score }
        .first(HINT_LIMIT)
    end

    private
      def score_sql(column)
        ActiveRecord::Base.sanitize_sql_array([
          "GREATEST(word_similarity(#{column}, :text), word_similarity(:text, #{column}), similarity(#{column}, :text))",
          text: @text
        ])
      end

      def scored_entries(threshold = THRESHOLD)
        score = score_sql("foods.name")

        MealEntry.joins(:user, :food)
          .where(users: { household_id: @user.household_id })
          .where(consumed_at: WINDOW.ago..)
          .where("#{score} >= ?", threshold)
          .select("meal_entries.*", "#{score} AS match_score")
          .order(Arel.sql("#{score} DESC"), consumed_at: :desc)
          .limit(HINT_LIMIT)
          .to_a
          .uniq(&:food_id)
      end

      # Foods carry nutrition but no portion — an imported row nobody has eaten yet.
      # Only rows that actually know their macros are worth mentioning.
      def scored_foods(threshold)
        score = score_sql("foods.name")

        Food.where.not(calories_per_100g: nil)
          .where("#{score} >= ?", threshold)
          .select("foods.*", "#{score} AS match_score")
          .order(Arel.sql("#{score} DESC"))
          .limit(HINT_LIMIT)
          .to_a
      end
  end
end
