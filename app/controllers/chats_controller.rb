class ChatsController < ApplicationController
  # The model only ever sees Conversation::WINDOW messages; the screen shows more than
  # that so you can scroll back through the day, but not the whole thread — after a
  # year this is a few thousand rows and none of them are worth rendering on open.
  TRANSCRIPT = 80

  def show
    @user = Current.user
    @conversation = @user.conversation!
    @messages = @conversation.messages.last(TRANSCRIPT).select(&:renderable?)
    @header_date = @user.local_today
  end
end
