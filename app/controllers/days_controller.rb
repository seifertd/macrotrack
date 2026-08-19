class DaysController < ApplicationController
  def show
    @user = Current.user
    @date = parse_local_date(params[:date])
    @header_date = @date
    @entries = @user.entries_on(@date).reverse_chronological.includes(:food)
    @totals = @user.day_totals(@date)
  end
end
