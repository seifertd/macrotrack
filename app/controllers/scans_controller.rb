# Barcode scanning (WP7, design §6 path 1). Ground truth, no inference: the label is
# read, not estimated, so nothing here touches the model or costs anything.
#
# Three outcomes from a scan, and the screen has to handle all of them:
#   1. We already have the barcode  → straight to the portion screen
#   2. OpenFoodFacts has it         → create the food, then the portion screen
#   3. Nobody has it                → adopt it by hand, which teaches us for next time
#
# (3) matters more than it looks. Coverage is patchy on store brands, and a dead end
# there would send every future scan of the same tub down the same dead end.
class ScansController < ApplicationController
  before_action :set_barcode, except: %i[ new lookup ]

  # The camera screen. All the work is in the `barcode` Stimulus controller — this only
  # has to exist and be reachable from the day view.
  def new
    @user = Current.user
  end

  # Where the typed-number form lands. Kept server-side on purpose: it is the fallback
  # for a browser without `BarcodeDetector` or with the camera refused, so routing it
  # through JS would make the fallback depend on the thing that just failed.
  def lookup
    barcode = Foods::OpenFoodFacts.normalize(params[:barcode])

    return redirect_to scan_path, alert: "That didn't look like a barcode." if barcode.blank?

    redirect_to scanned_path(barcode)
  end

  def show
    @user = Current.user
    found = Foods::OpenFoodFacts.find(@barcode)

    if found
      @food = found
      @portion = FoodPortion.new(@food)
    else
      # The adopt form needs something to bind to, and pre-setting the barcode means the
      # number on screen is the one that gets saved.
      @food = Food.new(barcode: @barcode)
      render :adopt
    end
  end

  def create
    food = Food.find_by!(barcode: @barcode)
    portion = FoodPortion.new(food, grams: params[:grams], servings: params[:servings])

    return redirect_to scanned_path(@barcode), alert: "That portion didn't look right." unless portion.loggable?

    entry = portion.log_for!(Current.user)

    redirect_to day_path(Current.user.local_date(entry.consumed_at)),
      notice: "Logged #{helpers.calories(entry.calories)} kcal."
  end

  # The manual fallback. Saves the barcode alongside the numbers, so the next scan of
  # this product — by either of us — resolves without asking again.
  def adopt
    @user = Current.user
    @food = Food.new(food_params.merge(barcode: @barcode, source: "user_custom"))

    if @food.save
      redirect_to scanned_path(@barcode)
    else
      render :adopt, status: :unprocessable_entity
    end
  end

  private
    def set_barcode
      @barcode = Foods::OpenFoodFacts.normalize(params[:barcode])

      redirect_to scan_path, alert: "That didn't scan as a barcode." if @barcode.blank?
    end

    def food_params
      params.require(:food).permit(:name, :calories_per_100g, :protein_per_100g, :carbs_per_100g,
        :fat_per_100g, :serving_g, :serving_label)
    end
end
