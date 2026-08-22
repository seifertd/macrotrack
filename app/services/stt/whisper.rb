module Stt
  # whisper.cpp, on our own box, decoding the upload itself — miniaudio reads mp3, wav and
  # flac, so there is no ffmpeg on das and nothing to install with a password.
  #
  # small.en, and the way we got there is worth keeping. The bake-off clip on 2026-08-22
  # was transcribed correctly by all three models, so base.en looked like the obvious pick
  # at 4 seconds against small.en's 12. The first real recording through the app said
  # otherwise: base.en heard "ITA meatballs" where the user said IKEA.
  #
  # Feeding the foods table in as whisper's initial prompt — the vocabulary biasing §6
  # designed, and the obvious fix — made it worse rather than better. It did not recover
  # the name, and it silently dropped "about 10 of them". A wrong count is a wrong calorie
  # figure, which is a worse failure than a wrong name the model can repair from context,
  # so there is no prompt here and there should not be one.
  #
  # small.en got every word, and 750MB of a 3GB box for eleven seconds is affordable. The
  # cost is real — twelve seconds rather than four — and §1 is the reason it is acceptable:
  # you press Done and put the phone down, so it is elapsed time rather than the
  # hands-and-attention time that this app is measured on.
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
      #
      # -bo 1 -bs 1 is greedy decoding instead of the default beam search, and -fa is
      # flash attention. Together they take a 22-second recording from 11.8s to 7.7s and
      # return byte-identical transcripts on both fixtures. Greedy is in principle less
      # robust on hard audio — it cannot back out of a bad guess — so if a recording ever
      # comes back worse than it sounds, drop these two flags before reaching for a
      # bigger model or a bigger box.
      stdout, stderr, status = Open3.capture3(
        binary, "-m", model, "-f", path.to_s,
        "-t", Rails.configuration.x.whisper_threads.to_s,
        "-bo", "1", "-bs", "1", "-fa", "-np", "-nt"
      )

      raise Error, "whisper failed: #{stderr.lines.last(3).join.strip}" unless status.success?

      stdout.strip.squeeze(" ")
    end
  end
end
