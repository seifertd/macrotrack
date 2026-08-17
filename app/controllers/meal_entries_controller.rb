class MealEntriesController < ApplicationController
  before_action :set_meal_entry, only: %i[ edit update destroy ]

  def create
    @meal_entry = Current.user.meal_entries.new(meal_entry_params)
    @meal_entry.source = "manual"
    @meal_entry.food = Food.find_or_create_by_name(@meal_entry.food_name)

    if @meal_entry.save
      redirect_to day_for(@meal_entry), notice: "Logged."
    else
      redirect_to day_path(Current.user.local_today),
        alert: @meal_entry.errors.full_messages.to_sentence
    end
  end

  def edit
    @meal_entry.food_name = @meal_entry.food&.name
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

    def day_for(entry)
      day_path(Current.user.local_date(entry.consumed_at))
    end
end
