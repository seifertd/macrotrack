module Stt
  # Every test in the suite runs through this, so a missing binary can't turn into a
  # 4-second subprocess by accident — the same guarantee Ai::FakeClient gives.
  class Fake
    # transcribed is the paths; read is how many bytes were on disk at each one when it was
    # called. The tempfile is gone by the time a test can look, so this is the only proof
    # that a real file was handed over rather than a key or a filename.
    attr_reader :transcribed, :read

    def initialize(transcript = "a bowl of chili", error: nil)
      @transcript = transcript
      @error = error
      @transcribed = []
      @read = []
    end

    def transcribe(path)
      @transcribed << path.to_s
      @read << File.size?(path.to_s)
      raise Error, @error if @error

      @transcript
    end
  end
end
