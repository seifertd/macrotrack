require "test_helper"

class VoiceEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear   # the rate-limit counter lives here and outlives an example
    sign_in_as users(:doug)
  end

  test "the recording is kept, transcribed, and joins the thread as a spoken turn" do
    with_transcript("ten ikea meatballs with mashed potatoes and gravy") do
      assert_enqueued_with job: AiChatTurnJob do
        post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
      end
    end

    message = Message.order(:created_at).last

    assert_equal "user", message.role
    assert_equal "voice", message.input_source, "meal_entries.source is copied from this"
    assert_equal "ten ikea meatballs with mashed potatoes and gravy", message.text
    assert message.audio.attached?, "§6: keep the audio — it is the only way to tell a mishearing from a misjudgement"
    assert_response :success
  end

  test "the transcript is what gets transcribed, not the filename or the blob" do
    provider = with_transcript("two eggs and toast") do
      post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
    end

    assert_equal 1, provider.transcribed.length
    assert_match(/\.mp3\z|\.wav\z|[0-9a-z]{20,}/, provider.transcribed.first, "a real file on disk was handed over")
  end

  # §7 path 1 does not care how the words arrived.
  test "a meal we have eaten before is offered rather than parsed, dictated or typed" do
    users(:partner).meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      food: Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    )

    assert_no_enqueued_jobs only: AiChatTurnJob do
      with_transcript("the burst cherry tomato pasta again") do
        post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
      end
    end

    assert_equal users(:doug).conversation!.messages.last.suggested_meal_entry.food.name,
      "Burst Cherry Tomato Pasta"
  end

  test "a recording of nothing is not handed to the model" do
    assert_no_enqueued_jobs only: AiChatTurnJob do
      with_transcript("   ") do
        post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
      end
    end

    message = Message.order(:created_at).last

    assert_equal "(nothing was said)", message.text
    assert_nil message.input_source, "nothing was said, so nothing can claim to have been spoken"
  end

  # Transcription runs inline, so a whisper that dies takes the request with it unless it
  # is caught. The recording is still kept: it is the evidence for what went wrong.
  test "a failed transcription says so instead of raising" do
    with_transcript(error: "whisper binary not found") do
      post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
    end

    assert_response :success
    assert_match(/make out that recording/, response.body)
    assert Message.order(:created_at).last.audio.attached?
  end

  test "a post with no audio is refused rather than creating an empty turn" do
    assert_no_difference -> { Message.count } do
      post voice_entries_path, params: { voice_entry: {} }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "requires a signed-in user" do
    sign_out

    post voice_entries_path, params: { voice_entry: { audio: recording } }

    assert_redirected_to new_session_path
  end
  # The point of the limit is what does *not* happen: transcription runs inline in a Puma
  # thread for 8-12s on both cores, and there are three threads. A refused upload has to be
  # turned away before whisper is handed anything, or the limit costs what it was meant to save.
  test "a burst of recordings is refused before it reaches whisper" do
    limit = 6

    provider = with_transcript("a bowl of chili") do
      limit.times { post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream }
      assert_response :success, "the limit itself must not bite someone genuinely dictating"

      assert_no_difference -> { Message.count } do
        post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream
      end
    end

    assert_response :too_many_requests
    assert_equal limit, provider.transcribed.length, "the refused upload still reached whisper"
  end

  # A refused dictation leaves the mic button mid-recording unless the composer comes back.
  test "a refused recording hands the composer back" do
    with_transcript do
      7.times { post voice_entries_path, params: { voice_entry: { audio: recording } }, as: :turbo_stream }
    end

    assert_response :too_many_requests
    assert_match(/turbo-stream action="replace" target="composer"/, response.body)
    assert_match(/Give it a moment/, response.body)
  end
end
