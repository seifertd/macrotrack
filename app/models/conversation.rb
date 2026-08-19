class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :last_meal_entry, class_name: "MealEntry", optional: true
  has_many :messages, -> { chronological }, dependent: :destroy, inverse_of: :conversation

  # Design §9: send the last ~10 turns. This is a quality argument, not a cost one —
  # a thread from three weeks ago is noise. Each turn is up to two rows (assistant,
  # then the tool results), so 20 rows is roughly the ten turns the doc asks for.
  WINDOW = 20

  def to_api_messages
    window.map { |message| { role: message.role, content: message.api_content } }
  end

  # The transcript behind the most recent request, stored on entries as raw_input so
  # a bad estimate can be read back against what was actually said.
  def last_user_text
    messages.reverse_each.find(&:text?)&.text if messages.any?
  end

  def last_input_source
    messages.reverse_each.find { |message| message.role == "user" && message.input_source.present? }
      &.input_source || "text"
  end

  private
    # Cutting the window mid-turn is the one way to build a request the API rejects:
    # a tool_result whose tool_use fell off the front is a 400, not a degraded reply.
    # So the window is trimmed forward to a plain user turn — the only place a
    # conversation can legally start.
    def window
      candidates = messages.last(WINDOW).to_a
      candidates.shift until candidates.empty? || startable?(candidates.first)
      candidates
    end

    def startable?(message)
      message.role == "user" && !message.tool_result?
    end
end
