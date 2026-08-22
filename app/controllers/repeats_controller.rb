class RepeatsController < ApplicationController
  before_action :set_source, only: %i[ show create ]

  # Searching reaches back further than browsing does. The 30-day window is what makes
  # an unsearched list short enough to scan; somebody typing a name has said which meal
  # they want, and "we ate that in March" is the answer they are looking for.
  SEARCH_WINDOW = 1.year
  # Raised from 20 with the ranking work: a cap that silently drops matches is the thing
  # being complained about, and no real search comes close to it — "chicken" returns 12
  # and "beef" 8 against a 224-food corpus. It exists only so a stray one-letter query,
  # which the substring match answers with 170 rows, does not render all of them.
  FOOD_LIMIT = 50

  # The screen Raquel asked for — what got eaten lately, tap one — plus, since WP4.4, a
  # way to reach a food nobody has eaten at all.
  def index
    @user = Current.user
    @query = params[:q].to_s.strip
    @entries = MealEntry.distinct_by_food(matching_entries)
    @foods = matching_foods
    # One ranked list when something was typed; the plain recent-meals picker otherwise,
    # where there is no query to be more or less confident about.
    @results = @query.present? ? ScoredByName.by_confidence(@entries + @foods.to_a) : @entries
    @header_date = @user.local_today
  end

  # Pick the portion before it is saved, not after — the number should be confirmed on
  # the way in.
  def show
    @user = Current.user
    @portion = MealPortion.new(@source)
    @header_date = @user.local_today
  end

  # Always onto your own day. You can pick from anyone's plate in the household, but you
  # can only log onto your own — same as the manual form and the chat. Writing to someone
  # else's day has one entry point, `copy_to_household_member` in the chat, where the
  # other person's name has to be said out loud.
  def create
    portion = MealPortion.new(@source, grams: params[:grams], multiplier: params[:multiplier])
    entry = portion.log_for!(Current.user)

    redirect_to day_path(Current.user.local_date(entry.consumed_at)),
      notice: "Logged #{helpers.calories(entry.calories)} kcal."
  end

  private
    # Any household member's entry can be picked from; nobody outside it can.
    def set_source
      @source = MealEntry.recent_in_household(Current.user.household, since: SEARCH_WINDOW.ago, limit: nil)
        .find(params[:id])
    end

    def matching_entries
      return MealEntry.recent_in_household(@user.household) if @query.blank?

      MealEntry.recent_in_household(@user.household, since: SEARCH_WINDOW.ago, limit: nil)
        .named_like(@query).scored_against(@query)
    end

    # Foods only ever answer a search. There is no honest way to rank a row nobody has
    # eaten — recency needs something to be recent — and WP4.5's ~141 recipes would bury
    # the handful of meals that are actually worth one tap.
    #
    # An entry already on screen still wins its food's slot: it carries a portion somebody
    # really ate, which beats a serving size every time. That is the one place the two
    # kinds are ranked against each other rather than by score, and it is a judgement
    # about usefulness — but it removes a row rather than reordering one, so the list the
    # user reads is still strictly best-match-first.
    def matching_foods
      return Food.none if @query.blank?

      Food.loggable.named_like(@query).scored_against(@query)
        .where.not(id: @entries.filter_map(&:food_id))
        .order(
          Arel.sql("#{Food.word_score_sql(@query, 'foods.name')} DESC"),
          Arel.sql("#{Food.whole_score_sql(@query, 'foods.name')} DESC"),
          :name
        )
        .limit(FOOD_LIMIT)
    end
end
