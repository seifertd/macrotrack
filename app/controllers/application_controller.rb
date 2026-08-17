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
end
