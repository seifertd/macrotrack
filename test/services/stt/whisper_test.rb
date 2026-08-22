require "test_helper"

# The subprocess handling, checked against a stand-in that behaves like whisper without
# being it — four seconds and a 141MB model do not belong in a test run. What is worth
# guarding is exactly what production caught on 2026-08-22: whisper narrates itself on
# stderr, and a transcript assembled from both streams would have logged
# "read_audio_data: trying to decode with miniaudio" as a meal.
class Stt::WhisperTest < ActiveSupport::TestCase
  setup do
    # Unique per test: the suite runs in parallel processes and they share tmp/.
    stem = "whisper-test-#{SecureRandom.hex(6)}"
    @binary = Rails.root.join("tmp", stem)
    @model = Rails.root.join("tmp", "#{stem}.bin")
    File.write(@model, "not really a model")

    Rails.configuration.x.whisper_binary = @binary.to_s
    Rails.configuration.x.whisper_model = @model.to_s
  end

  teardown do
    [ @binary, @model ].each { |path| File.delete(path) if File.exist?(path) }
    Rails.application.config.x.whisper_binary = nil
    Rails.application.config.x.whisper_model = nil
  end

  test "the transcript is stdout, and whisper's narration of itself is not part of it" do
    stub_whisper(out: " ten ikea meatballs with gravy\n", err: "read_audio_data: decoding with miniaudio\n")

    assert_equal "ten ikea meatballs with gravy", Stt::Whisper.new.transcribe("/tmp/clip.wav")
  end

  test "the run says which file and which model it was given" do
    # printf concatenates its arguments, so the flags arrive run together. What is being
    # checked is that the path follows -f and the model follows -m, not the spacing.
    stub_whisper(out: 'ok "$*"')
    said = Stt::Whisper.new.transcribe("/tmp/clip.wav")

    assert_match(%r{-f/tmp/clip\.wav}, said)
    assert_match(/-m#{Regexp.escape(@model.to_s)}/, said)
  end

  test "a failure is an Stt::Error carrying what whisper said about it" do
    stub_whisper(out: "", err: "error: failed to load model\n", status: 1)

    error = assert_raises(Stt::Error) { Stt::Whisper.new.transcribe("/tmp/clip.wav") }

    assert_match(/failed to load model/, error.message)
  end

  test "a missing binary or model is caught before anything is spawned" do
    File.delete(@model)
    stub_whisper(out: "never reached")

    assert_raises(Stt::Error) { Stt::Whisper.new.transcribe("/tmp/clip.wav") }

    Rails.configuration.x.whisper_binary = "/nonexistent/whisper-cli"
    assert_raises(Stt::Error) { Stt::Whisper.new.transcribe("/tmp/clip.wav") }
  end

  private
    def stub_whisper(out:, err: "", status: 0)
      File.write(@binary, <<~SH)
        #!/bin/sh
        printf %s "#{err}" >&2
        printf %s "#{out}"
        exit #{status}
      SH
      File.chmod(0o755, @binary)
    end
end
