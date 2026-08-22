# The §2 bake-off, and WP5-b's blocking step. Design §6: pick on accuracy of food nouns,
# not latency, so this transcribes one real clip with every provider it has a key for and
# counts which food nouns each one got.
#
#   DEEPGRAM_API_KEY=… bin/rails runner script/stt_bakeoff.rb CLIP.m4a \
#     --expect "roast beef,english muffin,magic juice"
#
# Keys come from the environment, deliberately: nothing here belongs in credentials until
# a provider has been chosen, and a bake-off that requires an encrypted-file edit before
# it will run is a bake-off nobody runs.
#
# The keyterm list is the point of the exercise. §6 designed vocabulary biasing around the
# `foods` table, and there are 190-odd rows in it now — this is the first time that claim
# faces a measurement rather than an argument.

clip = ARGV.first or abort "usage: bin/rails runner script/stt_bakeoff.rb CLIP.m4a [--expect \"a,b,c\"]"
abort "no such file: #{clip}" unless File.exist?(clip)

expected = ARGV.each_cons(2).find { |flag, _| flag == "--expect" }&.last.to_s.split(",").map(&:strip).reject(&:empty?)
audio = File.binread(clip)
mime = { ".m4a" => "audio/mp4", ".mp3" => "audio/mpeg", ".wav" => "audio/wav",
         ".ogg" => "audio/ogg", ".webm" => "audio/webm" }.fetch(File.extname(clip).downcase, "audio/mp4")

# Deepgram takes up to 100 plain terms. Most-eaten first: a term that has never been eaten
# is a term the recogniser does not need biasing towards.
KEYTERMS = Food.joins(:meal_entries).group("foods.id")
  .order(Arel.sql("COUNT(meal_entries.id) DESC")).limit(100).pluck(:name).freeze

def post(url, headers, body)
  response = Faraday.post(url, body) { |request| request.headers.merge!(headers) }
  return JSON.parse(response.body) if response.success?

  { "error" => "#{response.status}: #{response.body.to_s[0, 200]}" }
end

def deepgram(audio, mime, keyterms:)
  key = ENV["DEEPGRAM_API_KEY"] or return nil

  query = { model: "nova-3", smart_format: "true" }.to_query
  query += "&" + keyterms.map { |term| "keyterm=#{CGI.escape(term)}" }.join("&") if keyterms.any?

  body = post("https://api.deepgram.com/v1/listen?#{query}",
    { "Authorization" => "Token #{key}", "Content-Type" => mime }, audio)

  body.dig("results", "channels", 0, "alternatives", 0, "transcript") || body["error"]
end

# Two-step and worth the extra call: the 1,000-term ceiling is the reason §2 keeps it on
# the list, and it only shows up on a corpus bigger than Deepgram's 100.
def assemblyai(audio, keyterms:)
  key = ENV["ASSEMBLYAI_API_KEY"] or return nil

  uploaded = post("https://api.assemblyai.com/v2/upload", { "Authorization" => key }, audio)
  return uploaded["error"] if uploaded["error"]

  job = post("https://api.assemblyai.com/v2/transcript",
    { "Authorization" => key, "Content-Type" => "application/json" },
    { audio_url: uploaded["upload_url"], keyterms_prompt: keyterms.first(1000) }.to_json)
  return job["error"] if job["error"]

  30.times do
    sleep 2
    result = JSON.parse(Faraday.get("https://api.assemblyai.com/v2/transcript/#{job['id']}",
      nil, { "Authorization" => key }).body)

    return result["text"] if result["status"] == "completed"
    return result["error"] if result["status"] == "error"
  end

  "(still processing after a minute)"
end

# Multipart by hand rather than adding faraday-multipart for a script that runs once.
def groq(audio, clip, mime)
  key = ENV["GROQ_API_KEY"] or return nil

  boundary = "----bakeoff#{SecureRandom.hex(8)}"
  body = +""
  body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"
  # Whisper's `prompt` is a soft nudge rather than a keyword booster (§2), but it is the
  # only biasing on offer here, so it gets the same list to work with.
  body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n#{KEYTERMS.first(30).join(', ')}\r\n"
  body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; " \
          "filename=\"#{File.basename(clip)}\"\r\nContent-Type: #{mime}\r\n\r\n"
  body = body.b + audio.b + "\r\n--#{boundary}--\r\n".b

  result = post("https://api.groq.com/openai/v1/audio/transcriptions",
    { "Authorization" => "Bearer #{key}", "Content-Type" => "multipart/form-data; boundary=#{boundary}" }, body)

  result["text"] || result["error"]
end

# The measurement §6 actually asked for: not word error rate, which is dominated by filler
# nobody cares about, but whether the food came through by name.
def score(transcript, expected)
  return "" if expected.empty? || transcript.to_s.empty?

  said = transcript.downcase
  hit, missed = expected.partition { |term| said.include?(term.downcase) }

  "  → #{hit.size}/#{expected.size} food nouns#{missed.any? ? " — missed #{missed.join(', ')}" : ""}"
end

puts "clip: #{clip} (#{(audio.bytesize / 1024.0).round}KB, #{mime})"
puts "keyterms: #{KEYTERMS.size} foods, most-eaten first — #{KEYTERMS.first(5).join(', ')}…"
puts "expecting: #{expected.join(', ')}" if expected.any?
puts

runs = {
  "Deepgram nova-3 (no keyterms)" => -> { deepgram(audio, mime, keyterms: []) },
  "Deepgram nova-3 + keyterms" => -> { deepgram(audio, mime, keyterms: KEYTERMS) },
  "AssemblyAI + keyterms_prompt" => -> { assemblyai(audio, keyterms: KEYTERMS) },
  "Groq whisper-large-v3-turbo" => -> { groq(audio, clip, mime) }
}

runs.each do |label, run|
  started = Time.current
  transcript = run.call

  if transcript.nil?
    puts "#{label}: skipped, no key in the environment"
    next
  end

  puts "#{label} (#{(Time.current - started).round(1)}s):"
  puts "  #{transcript}"
  puts score(transcript, expected)
  puts
end
