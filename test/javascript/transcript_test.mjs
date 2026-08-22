import { test } from "node:test"
import assert from "node:assert/strict"
import Transcript from "../../app/javascript/lib/transcript.js"

// The recogniser's own shape: `results` is an array-like of results, each an array-like
// of alternatives, each alternative carrying a `transcript`.
const said = (text, isFinal = true) => ({ isFinal, 0: { transcript: text } })

// One utterance as Chrome on Android reports it across events: the same result again and
// again, each report a longer prefix of the sentence.
const growing = (sentence) =>
  sentence.split(" ").map((_, i) => [ said(sentence.split(" ").slice(0, i + 1).join(" ")) ])

// And as it reports it within a single event: every reading of the sentence so far,
// sitting in one results array. Production, 22 August, logged by the matcher as
// query="two two small two small figs".
const piledUp = (sentence) =>
  [ sentence.split(" ").map((_, i) => said(sentence.split(" ").slice(0, i + 1).join(" "))) ]

const hearAll = (transcript, sessions) => {
  for (const events of sessions) {
    for (const results of events) transcript.hear(results)
    transcript.close()
  }

  return transcript.text()
}

const SENTENCE = "I'm going to have one serving of magic juice"

test("a result reported over and over is one sentence, not one per report", () => {
  // Appending instead of rebuilding shipped this as "I'mI'm going toI'm going to have…"
  // on 22 August, and the model logged the right meal out of it anyway.
  assert.equal(hearAll(new Transcript(), [ growing(SENTENCE) ]), SENTENCE)
})

test("every reading piled into one event is one sentence, not all of them", () => {
  // The first fix missed this shape and shipped "two two small two small figs".
  assert.equal(hearAll(new Transcript(), [ piledUp("two small figs") ]), "two small figs")
  assert.equal(hearAll(new Transcript(), [ piledUp(SENTENCE) ]), SENTENCE)
})

test("a reading that grows is the same reading, whether it arrives piled up or spread out", () => {
  const spread = hearAll(new Transcript(), [ growing(SENTENCE) ])
  const piled = hearAll(new Transcript(), [ piledUp(SENTENCE) ])

  assert.equal(spread, piled)
})

test("readings only supersede within their own session", () => {
  // "and" then "and toast" is one utterance growing; "two eggs" before it is not.
  const sessions = [ [ [ said("two eggs") ] ], [ [ said("and"), said("and toast") ] ] ]

  assert.equal(hearAll(new Transcript(), sessions), "two eggs and toast")
})

test("the interim reading is shown as it firms up, never accumulated", () => {
  const transcript = new Transcript()

  assert.equal(transcript.hear([ said("two eggs", false) ]), "two eggs")
  assert.equal(transcript.hear([ said("two eggs and", false) ]), "two eggs and")
  assert.equal(transcript.hear([ said("two eggs and toast") ]), "two eggs and toast")
})

test("a restart that replays audio already transcribed does not say it twice", () => {
  const replayed = [ growing(SENTENCE), [ [ said("of magic juice") ] ] ]

  assert.equal(hearAll(new Transcript(), replayed), SENTENCE)
})

test("a genuine second sentence across a restart is kept", () => {
  const rambled = [ growing(SENTENCE), [ [ said("and a slice of toast") ] ] ]

  assert.equal(hearAll(new Transcript(), rambled), `${SENTENCE} and a slice of toast`)
})

test("a session that ends mid-word keeps what was still interim", () => {
  const cutOff = [ [ [ said("I'm going to have"), said("one serving of magic juice", false) ] ] ]

  assert.equal(hearAll(new Transcript(), cutOff), SENTENCE)
})

test("hearing nothing at all is empty rather than whitespace", () => {
  // A session opened and closed without a word said, and one that heard only silence.
  assert.equal(hearAll(new Transcript(), [ [] ]), "")
  assert.equal(hearAll(new Transcript(), [ [ [ said("") ] ] ]), "")
  assert.equal(new Transcript().text(), "")
})

test("several results in one event are one sentence in the order they arrived", () => {
  const transcript = new Transcript()

  assert.equal(
    transcript.hear([ said("two eggs"), said("and toast"), said("with butter", false) ]),
    "two eggs and toast with butter"
  )
})
