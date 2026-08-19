# Design §8: model choice is a config value so it stops being a decision. Opus 5 is
# the default because meal descriptions and voice transcripts are exactly the input
# it is best at; claude-sonnet-5 saves a few dollars a month if that ever matters.
Rails.application.configure do
  config.x.ai_model = ENV.fetch("AI_MODEL", "claude-opus-5")

  # Structured extraction against a tight schema, not hard reasoning. Step up to
  # "medium" if parses come back shallow.
  config.x.ai_effort = ENV.fetch("AI_EFFORT", "low")

  # Thinking and response text share this budget (§8). Sizing it around the answer
  # alone truncates mid-response.
  config.x.ai_max_tokens = Integer(ENV.fetch("AI_MAX_TOKENS", 8192))
end
