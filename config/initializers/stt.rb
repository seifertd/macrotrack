# whisper.cpp lives in the deploying user's home directory rather than anywhere privileged,
# because installing it needed no root and pinning it to /usr/local would have.
Rails.application.configure do
  home = ENV.fetch("HOME", "/home/doug")

  config.x.whisper_binary = ENV.fetch("WHISPER_BINARY", "#{home}/whisper.cpp/build/bin/whisper-cli")
  config.x.whisper_model = ENV.fetch("WHISPER_MODEL", "#{home}/whisper.cpp/models/ggml-small.en.bin")
  # das has two cores and Puma and Postgres want them too, and whisper takes both of them:
  # Stt::Whisper shells out with Open3.capture3 at normal priority, inline in one of Puma's
  # three threads, with SOLID_QUEUE_IN_PUMA=1 putting the job workers in that same process.
  # Nothing nices it — this line used to claim the caller did, which was never true. The
  # inline trade is deliberate (see voice_entries_controller.rb) and the box is ours, so the
  # honest note is that a transcription briefly owns the machine. WHISPER_THREADS=1 is the
  # lever if that ever stops being acceptable.
  config.x.whisper_threads = Integer(ENV.fetch("WHISPER_THREADS", 2))
end
