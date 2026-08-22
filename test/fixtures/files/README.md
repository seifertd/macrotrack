# ramble.mp3

The WP5-b bake-off clip, recorded on the Pixel on 2026-08-22. 21.1 seconds, and
deliberately the hard case §2 asks for: a recipe name from our own corpus, a
self-correction, spoken portions, and a cooking fat.

> "10 meatballs, I mean IKEA meatballs, 10 IKEA meatballs with mashed potatoes and
> gravy, about half a cup of mashed potatoes, quarter cup of gravy, and some roast
> broccoli cooked in olive oil."

Every whisper.cpp model transcribed it correctly, self-correction included. Keep it:
it is the regression fixture for anything that touches transcription.

## What the second recording changed

The clip above was transcribed correctly by every model, which made `base.en` look like
the obvious pick — four seconds against `small.en`'s twelve. The first real recording
made through the app, on the same day, disagreed: `base.en` heard "ITA meatballs" for
IKEA. Feeding the foods table in as whisper's initial prompt did not recover the name and
silently dropped "about 10 of them", which is the worse failure of the two — the model
can repair a mangled name from context and cannot invent a quantity nobody said.

`small.en`, no prompt, got every word. That recording is still in production storage,
which is what §6 means by keeping the audio: without it this would have been a guess.
