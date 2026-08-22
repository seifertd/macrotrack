module Stt
  # Every test in the suite runs through this, so a missing binary can't turn into a
  # 4-second subprocess by accident — the same guarantee Ai::FakeClient gives.
  class Fake
    attr_reader :transcribed

    def initialize(transcript = "a bowl of chili", error: nil)
      @transcript = transcript
      @error = error
      @transcribed = []
    end

    def transcribe(path)
      @transcribed << path.to_s
      raise Error, @error if @error

      @transcript
    end
  end
end
