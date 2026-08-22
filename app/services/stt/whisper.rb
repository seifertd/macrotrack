module Stt
  # whisper.cpp, on our own box, decoding the upload itself — miniaudio reads mp3, wav and
  # flac, so there is no ffmpeg on das and nothing to install with a password.
  #
  # base.en, and that is measured rather than assumed: on 2026-08-22 a 21-second clip took
  # 2.2s on tiny.en, 3.9s on base.en and 12.0s on small.en, and all three transcribed it
  # correctly, self-correction and all. base.en is the middle one for the same reason you
  # would pick it anywhere — a little more room to be wrong, at a cost nobody notices.
  class Whisper
    def transcribe(path)
      binary = Rails.configuration.x.whisper_binary
      model = Rails.configuration.x.whisper_model

      raise Error, "whisper binary not found at #{binary}" unless File.executable?(binary)
      raise Error, "whisper model not found at #{model}" unless File.exist?(model)

      # capture3, not capture2e, and that distinction is the whole of this method. whisper
      # narrates itself on stderr — "reading audio data…", "trying to decode with
      # miniaudio" — so merging the two streams makes its diagnostics part of the meal.
      # stdout is the transcript; stderr is only worth reading when it failed.
      #
      # -np no progress, -nt no timestamps, -t threads.
      stdout, stderr, status = Open3.capture3(
        binary, "-m", model, "-f", path.to_s,
        "-t", Rails.configuration.x.whisper_threads.to_s, "-np", "-nt"
      )

      raise Error, "whisper failed: #{stderr.lines.last(3).join.strip}" unless status.success?

      stdout.strip.squeeze(" ")
    end
  end
end
