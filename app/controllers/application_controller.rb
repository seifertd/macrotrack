class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Everything inside a request runs in the signed-in user's zone, so submitted
  # datetimes are parsed and rendered in the same zone the rollups use.
  around_action :use_user_time_zone, if: :authenticated?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    def use_user_time_zone(&block)
      Time.use_zone(Current.user.timezone, &block)
    end

    # Where every portion screen ends: the scanner, the food picker and the repeat picker
    # all log onto the current user's own day and then show it to them. Written once so the
    # three cannot drift on which day they land on or what the confirmation says.
    def redirect_to_logged_day(entry)
      redirect_to day_path(Current.user.local_date(entry.consumed_at)),
        notice: "Logged #{helpers.calories(entry.calories)} kcal."
    end

    # A :date param resolved in the user's own zone. The route constraint only checks
    # the shape, so a well-formed nonsense date still gets here and falls back to today
    # rather than raising. Shared by the day page and the add screen, which have to
    # agree on which day they are looking at.
    def parse_local_date(value)
      Date.parse(value)
    rescue ArgumentError, TypeError
      Current.user.local_today
    end
end
