# whisper.cpp lives in the deploying user's home directory rather than anywhere privileged,
# because installing it needed no root and pinning it to /usr/local would have.
Rails.application.configure do
  home = ENV.fetch("HOME", "/home/doug")

  config.x.whisper_binary = ENV.fetch("WHISPER_BINARY", "#{home}/whisper.cpp/build/bin/whisper-cli")
  config.x.whisper_model = ENV.fetch("WHISPER_MODEL", "#{home}/whisper.cpp/models/ggml-base.en.bin")
  # das has two cores and Puma and Postgres want them too. Both, but niced by the caller.
  config.x.whisper_threads = Integer(ENV.fetch("WHISPER_THREADS", 2))
end
