# Ranking a typed search, for both halves of what it can turn up.
#
# The two are ranked together because they are one answer to one question. Splitting them
# into "you've eaten these" and "on file, never logged" put a recipe called Portobello
# Sandwich under a second heading below a chicken soup, where searching "porto" looked
# like it had missed — the row was on the page, under a heading nobody had a reason to
# read. What kind of row it is belongs on the row, as a chip, not in the sort order.
module ScoredByName
  extend ActiveSupport::Concern

  class_methods do
    # Carries the two ranking measures back with each row. Selected rather than ordered in
    # SQL because entries are deduplicated by food in Ruby first — the row kept for a food
    # must be the most recent portion somebody ate — and only then does the whole mixed
    # list get put in order.
    def scored_against(query)
      select(
        "#{table_name}.*",
        "#{Food.word_score_sql(query, *search_columns)} AS word_score",
        "#{Food.whole_score_sql(query, *search_columns)} AS whole_score"
      )
    end
  end

  # Best match first, across whatever mix of rows it is given.
  def self.by_confidence(rows)
    rows.sort_by { |row| [ -row.word_score.to_f, -row.whole_score.to_f, row.display_name.downcase ] }
  end
end
