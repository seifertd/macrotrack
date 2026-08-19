class DaysController < ApplicationController
  def show
    @user = Current.user
    @date = parse_date
    @header_date = @date
    @entries = @user.entries_on(@date).reverse_chronological.includes(:food)
    @totals = @user.day_totals(@date)
    @meal_entry = @user.meal_entries.new(consumed_at: default_consumed_at, source: "manual")
  end

  private
    def parse_date
      Date.parse(params[:date])
    rescue ArgumentError, TypeError
      @user.local_today
    end

    # Prefill "now" in the user's own zone, not the server's.
    def default_consumed_at
      Time.current.in_time_zone(@user.timezone)
    end
end
