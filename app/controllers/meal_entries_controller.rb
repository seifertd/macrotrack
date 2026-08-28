class MealEntriesController < ApplicationController
  before_action :set_meal_entry, only: %i[ edit update destroy ]

  # `edit` is re-rendered by a failed `update`, where the entry holds whatever was just
  # submitted — including a blank "When", which is one of the things that can fail. The
  # view's own header link has to resolve a day from that, so it uses this rather than
  # calling `local_date` on a nil and raising over the top of the error it was rendering
  # to show.
  helper_method :entry_date

  # The add screen: every way into the log on one page, reached from the header so it
  # stays one tap away however long the day's list gets. It carries the day it was
  # opened from, because logging to today while looking at the 16th is the same kind of
  # contradiction the header strip already avoids.
  def new
    @date = parse_local_date(params[:date])
    @header_date = @date
    @meal_entry = Current.user.meal_entries.new(consumed_at: default_consumed_at, source: "manual")
  end

  def create
    @meal_entry = Current.user.meal_entries.new(meal_entry_params)
    @meal_entry.source = "manual"
    @meal_entry.food = Food.find_or_create_by_name(@meal_entry.food_name)

    if @meal_entry.save
      redirect_to day_for(@meal_entry), notice: "Logged."
    else
      # Back to the screen the form lives on, still pointed at the day it was for,
      # rather than bouncing to today with an alert and no way back to the context.
      redirect_to new_meal_entry_path(date: entry_date(@meal_entry)),
        alert: @meal_entry.errors.full_messages.to_sentence
    end
  end

  def edit
    @meal_entry.food_name = @meal_entry.food&.name
    @header_date = Current.user.local_date(@meal_entry.consumed_at)
  end

  def update
    @meal_entry.assign_attributes(meal_entry_params)
    @meal_entry.food = Food.find_or_create_by_name(@meal_entry.food_name)

    if @meal_entry.save
      redirect_to day_for(@meal_entry), notice: "Updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    day = day_for(@meal_entry)
    @meal_entry.destroy!
    redirect_to day, notice: "Deleted."
  end

  private
    # Scoped to the current user, so one account can never reach the other's entries
    # even though the food database is shared.
    def set_meal_entry
      @meal_entry = Current.user.meal_entries.find(params[:id])
    end

    def meal_entry_params
      params.expect(meal_entry: %i[ food_name quantity_grams calories protein_g fat_g
                                    carbs_g meal_type consumed_at ])
    end

    def entry_date(entry)
      entry.consumed_at ? Current.user.local_date(entry.consumed_at) : Current.user.local_today
    end

    def day_for(entry)
      day_path(entry_date(entry))
    end

    # Prefill the clock only where it means something. On today that is now; on a day
    # already over, "now" stamps this evening onto a day that ended days ago — plausible
    # enough to be accepted unedited, and wrong. Noon reads as the placeholder it is.
    def default_consumed_at
      @date == Current.user.local_today ? Time.current : @date.noon
    end
end
