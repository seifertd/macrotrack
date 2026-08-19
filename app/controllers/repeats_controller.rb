class RepeatsController < ApplicationController
  before_action :set_source, only: %i[ show create ]

  # The screen Raquel asked for: what got eaten lately, tap one.
  def index
    @user = Current.user
    @entries = MealEntry.distinct_by_food(
      MealEntry.recent_in_household(@user.household)
    )
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
      @source = MealEntry.recent_in_household(Current.user.household, since: 1.year.ago, limit: nil)
        .find(params[:id])
    end
end
