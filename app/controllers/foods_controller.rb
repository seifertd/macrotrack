# A portion screen for a food nobody has eaten yet (WP4.4).
#
# The barcode path built this screen first, but keyed on the barcode — so the only way
# back to a scanned tub is to hold it up to the camera again. An imported recipe has no
# barcode and no entry behind it, which left it reachable by name in the chat and nowhere
# else: a `foods` row whose only observable effect was a line in a prompt.
#
# Keyed on the food, so it works for both, and for anything WP4.5 imports.
class FoodsController < ApplicationController
  before_action :set_food

  def show
    @user = Current.user
    @portion = FoodPortion.new(@food)
    @header_date = @user.local_today

    # Reachable by URL for a row the picker would never list. Most of `foods` is still
    # names the chat invented with no macros behind them, and there is nothing to put on
    # this screen for one of those.
    redirect_to repeats_path, alert: "We don't know what's in #{@food.name} yet." unless @portion.loggable?
  end

  # Onto your own day, like every other path except the chat's copy_to_household_member.
  def create
    portion = FoodPortion.new(@food, grams: params[:grams], servings: params[:servings])

    return redirect_to food_path(@food), alert: "That portion didn't look right." unless portion.loggable?

    # `matched`, not `manual`: the numbers came off a row we already had rather than
    # being typed or estimated, which is exactly what `matched` means everywhere else.
    entry = portion.log_for!(Current.user, logged_as: "matched")

    redirect_to_logged_day(entry)
  end

  private
    # Unscoped by household on purpose: `foods` is shared between everyone, and always
    # has been — the row carries a name and its macros, never who ate it.
    def set_food
      @food = Food.find(params[:id])
    end
end
