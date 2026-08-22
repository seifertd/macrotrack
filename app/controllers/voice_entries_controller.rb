# WP5-b. A recording arrives, is kept, is transcribed on our own box, and then joins the
# thread as an ordinary user turn — from the transcript onward nothing here is special,
# which is the point: retrieval, the tool loop and the day's log all already work.
class VoiceEntriesController < ApplicationController
  include OffersRetrieval

  def create
    audio = params.dig(:voice_entry, :audio)
    return head :unprocessable_entity if audio.blank?

    @conversation = Current.user.conversation!
    @message = @conversation.messages.create!(
      role: "user", input_source: "voice", content: [ { "type" => "text", "text" => "…" } ]
    )
    @message.audio.attach(audio)

    transcribe

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end

  private
    # Transcription is inline rather than in a job, and that is a deliberate trade. It is
    # four seconds of a Puma thread on a two-core box, which is the sort of thing that
    # normally belongs in a job — but the transcript is what the user is waiting to see,
    # and handing it to Solid Queue would mean a second broadcast, a second failure path
    # and a spinner that cannot say which half it is waiting on. Revisit if two people
    # ever record at the same moment.
    def transcribe
      text = @message.audio.blob.open { |file| Stt.transcribe(file.path) }

      if text.blank?
        @message.update!(content: [ { "type" => "text", "text" => "(nothing was said)" } ])
        return @message.update!(input_source: nil)
      end

      @message.update!(content: [ { "type" => "text", "text" => text } ])
      @suggestion = offer_retrieval(@conversation, text)
      AiChatTurnJob.perform_later(@conversation) unless @suggestion
    rescue Stt::Error => e
      Rails.logger.error("transcription failed: #{e.message}")
      @failure = "Couldn't make out that recording. Try again, or type it."
      @message.update!(content: [ { "type" => "text", "text" => "(couldn't transcribe that)" } ])
    end
end
