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

  def create
    target = target_user
    portion = MealPortion.new(@source, grams: params[:grams], multiplier: params[:multiplier])
    entry = portion.log_for!(target)

    redirect_to day_path(target.local_date(entry.consumed_at)),
      notice: "Logged #{helpers.calories(entry.calories)} kcal for #{target.name}."
  end

  private
    # Any household member's entry can be picked from; nobody outside it can.
    def set_source
      @source = MealEntry.recent_in_household(Current.user.household, since: 1.year.ago, limit: nil)
        .find(params[:id])
    end

    # "For me" / "For <name>" rather than a copy that always means *the other one*, so the
    # screen works the same whichever of us is holding the phone.
    def target_user
      return Current.user if params[:target_id].blank? || params[:target_id].to_i == Current.user.id

      Current.user.household.users.find(params[:target_id])
    end
end
