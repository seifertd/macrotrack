class Conversation < ApplicationRecord
  belongs_to :user
  has_many :messages, -> { chronological }, dependent: :destroy, inverse_of: :conversation

  # Design §9: send the last ~10 turns. This is a quality argument, not a cost one —
  # a thread from three weeks ago is noise. Each turn is up to two rows (assistant,
  # then the tool results), so 20 rows is roughly the ten turns the doc asks for.
  WINDOW = 20

  def to_api_messages
    window.map { |message| { role: message.role, content: message.api_content } }
  end

  # The transcript behind the most recent request, stored on entries as raw_input so
  # a bad estimate can be read back against what was actually said. Only turns the user
  # actually typed or dictated count: tool results are stored as user rows, and so is
  # the answer to a suggestion, but nobody said either of them. Dropping the role check
  # entirely — which this did — also let an assistant turn answer for the user, and the
  # one place that happens is a declined suggestion, whose text then came back as the
  # thing to be estimated.
  def last_user_text
    recent_first.find(&:spoken?)&.text
  end

  # Whether a turn is in flight. The screen learns this from a broadcast while it is
  # open, and has no way to learn it at all when it wasn't — a reload mid-turn, or the
  # redirect that lands you here from the Add screen's "Speak it". Two minutes because a
  # turn still running after that has failed, and an indicator that never stops is worse
  # than one that never starts.
  def awaiting_reply?
    last = messages.last

    last&.role == "user" && last.created_at.after?(2.minutes.ago)
  end

  def last_input_source
    recent_first.find { |message| message.role == "user" && message.input_source.present? }
      &.input_source || "text"
  end

  private
    # Newest first, bounded. `messages.reverse_each` — which both callers above used to
    # do — is not a relation method, so it fell through to Enumerable and loaded the whole
    # thread to look at the last row or two; ChatsController already notes this is "a few
    # thousand rows after a year", and `last_user_text` runs on every chat turn.
    #
    # `reorder`, not `order`: the association carries a `chronological` default, and
    # appending would leave ASC winning and hand back the oldest rows instead of the
    # newest. WINDOW is the same bound the request itself uses — a spoken turn older than
    # the context being sent is not the transcript this turn is about anyway.
    def recent_first
      messages.reorder(created_at: :desc, id: :desc).limit(WINDOW)
    end

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
