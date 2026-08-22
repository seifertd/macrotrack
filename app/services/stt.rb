# Design §6's one-method interface, and the seam that keeps the test suite off the audio
# pipeline entirely — the same shape as Ai.client, for the same reason.
#
# §6 assumed this would front a paid provider with vocabulary biasing. It fronts
# whisper.cpp on das instead: one recording measured on 2026-08-22 said every model got
# every food noun, biasing included nothing worth its latency, and self-hosting turned out
# to need no signup, no card and no sudo. The interface is unchanged, so if that ever
# stops being true a hosted provider drops in behind it.
module Stt
  mattr_accessor :provider, default: nil

  def self.transcribe(path)
    (provider || Stt::Whisper.new).transcribe(path)
  end

  def self.with_provider(replacement)
    previous = self.provider
    self.provider = replacement
    yield
  ensure
    self.provider = previous
  end

  class Error < StandardError; end
end
