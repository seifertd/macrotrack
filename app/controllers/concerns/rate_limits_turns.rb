# A bound on the two endpoints that cost something other than a database row.
#
# Both are authenticated and there are two accounts, so this is not a door being held
# shut — it is a stuck client being stopped from running up a bill or sitting on the
# box. The two costs are different, which is why the limits are:
#
#   Typed turns are money. Each one is up to MAX_ITERATIONS claude-opus-5 calls with an
#   8192-token budget, and nothing coalesces a resubmit — every POST writes a Message and
#   enqueues a job.
#
#   Dictated turns are the machine. Transcription runs inline in the request thread for
#   8-12 seconds on both cores (voice_entries_controller.rb explains why inline), Puma has
#   three threads, and SOLID_QUEUE_IN_PUMA=1 puts the workers in that same process. Enough
#   of them at once and the site stops answering for the person who isn't recording.
#
# Worth being honest about the limit of this: it bounds a *runaway*, not concurrency. Two
# people genuinely recording at the same moment still take two threads. Serialising that
# needs a lock, not a counter, and at two users it has not been worth one.
module RateLimitsTurns
  extend ActiveSupport::Concern

  # Said on screen rather than logged. The realistic cause is a client retrying, so the
  # message is what to do about it, not an accusation.
  REFUSAL = "That went through a lot at once. Give it a moment and try again.".freeze

  class_methods do
    # Keyed on the user, not `rate_limit`'s default of request.remote_ip: both accounts sit
    # behind one household NAT, so an IP-keyed counter would let one person's runaway client
    # lock the other out of their own tracker.
    def rate_limit_turns(to:, within:)
      rate_limit to: to, within: within,
        by: -> { Current.user.id },
        with: -> { refuse_turn },
        only: :create
    end
  end

  private
    # The composer is replaced on the way out for the same reason the success path replaces
    # it: a dictation that was refused leaves the mic button mid-recording, and a composer
    # that never comes back reads as the app having died rather than having said no.
    def refuse_turn
      @failure = REFUSAL

      respond_to do |format|
        format.turbo_stream { render "chats/throttled", status: :too_many_requests }
        format.html { redirect_to chat_path, alert: REFUSAL }
      end
    end
end
