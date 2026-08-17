# The implementation plan, readable in the app so it can be shared with the
# household without publishing it anywhere. Authentication is inherited from
# ApplicationController, so this is visible to signed-in users only.
class PlanController < ApplicationController
  layout "plan"

  def show
    return head :not_found unless PlanDocument.exists?

    @body, @packages = PlanDocument.render
  end
end
