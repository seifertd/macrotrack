require "test_helper"

class FoodTest < ActiveSupport::TestCase
  # The search rule (WP4.4). Worth its own test because the threshold was tuned against
  # measurements, and a threshold with no test is a threshold that drifts.
  class SearchTest < ActiveSupport::TestCase
    setup do
      @juice = create("Magic Juice")
      @stew  = create("Tofu Stew")
      @rice  = create("Tofu Fried Rice")
      @soup  = create("Spicy Curry Lentil Soup")
    end

    test "finds an exact name" do
      assert_includes Food.named_like("Magic Juice"), @juice
    end

    test "finds a half-typed word" do
      assert_includes Food.named_like("mag"), @juice
    end

    # The one thing the substring clause is load-bearing for: a query this short says
    # nothing to a trigram, and drops under the threshold on its own.
    test "finds a one-letter query the trigram measure would miss" do
      assert_operator similarity("m", "Magic Juice"), :<, Food::SEARCH_SIMILARITY
      assert_includes Food.named_like("m"), @juice
    end

    test "finds a name typed in the middle of another" do
      assert_includes Food.named_like("curry lentil"), @soup
    end

    test "finds a typo, which no substring match would" do
      assert_includes Food.named_like("magik juice"), @juice
      assert_includes Food.named_like("lentle soup"), @soup
    end

    test "is case-insensitive both ways" do
      assert_includes Food.named_like("MAGIC"), @juice
      assert_includes create("BOURBON SAUCE").then { |f| Food.named_like("bourbon") }, Food.find_by(name: "BOURBON SAUCE")
    end

    # The measured margin: a typo lands at 0.71 and up against the row it meant, while
    # the strongest wrong row any mistyped name pulled up sat at 0.56. This is that
    # 0.56 pair, and it stays out.
    test "a near-miss on a different dish stays out" do
      assert_not_includes Food.named_like("tofu stw"), @rice
      assert_includes Food.named_like("tofu stw"), @stew
    end

    test "matches nothing when nothing matches" do
      assert_empty Food.named_like("wombat wellington")
    end

    # A `%` typed into the search box is a character, not a wildcard. Asserted against a
    # row the wildcard alone would reach — *Magic Juice* comes back either way, on the
    # trigram clause, so it proves nothing about the escaping.
    test "a wildcard in the query is a literal" do
      assert_not_includes Food.named_like("magic%stew"), @stew
      assert_not_includes Food.named_like("magic%stew"), @juice
    end

    # Most of this table is names the chat invented with no macros behind them. They are
    # findable, but they cannot be offered a portion, so the picker asks for both.
    test "loggable keeps only rows that know their calories" do
      nameless = create("Nameless Stew", calories_per_100g: nil)

      assert_includes Food.loggable, @juice
      assert_not_includes Food.loggable, nameless
    end

    private
      def create(name, calories_per_100g: 71.87)
        Food.create!(name: name, source: "user_custom", calories_per_100g: calories_per_100g)
      end

      def similarity(query, name)
        Food.connection.select_value(
          Food.sanitize_sql_array([ "SELECT word_similarity(?, ?)", query, name ])
        ).to_f
      end
  end
end
