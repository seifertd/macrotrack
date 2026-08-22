module SttTestHelper
  # Swaps in a provider for one example — a different transcript, or a failure.
  def with_transcript(transcript = "a bowl of chili", error: nil)
    provider = Stt::Fake.new(transcript, error: error)
    Stt.with_provider(provider) { yield provider }
    provider
  end

  # A real wav, so what the controller attaches is what Active Storage would really get.
  def recording(name = "recording.wav")
    Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/ramble.mp3"), "audio/wav", original_filename: name
    )
  end
end
