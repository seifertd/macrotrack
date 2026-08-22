// What the recogniser said, assembled (WP5-a).
//
// Split out of dictation_controller because it is the half with a right answer: given a
// sequence of `result` events it produces one sentence, and that can be checked without
// a microphone, a browser, or a person willing to say "magic juice" into a phone. The
// controller keeps the parts that genuinely need a device — permissions, timers, the
// recogniser's own lifecycle — and this keeps the parts that don't.
//
// Chrome on Android does not report a sentence once. It reports it over and over, each
// reading one word longer than the last — "I'm", "I'm going to", "I'm going to have" —
// and it does this both across events *and* within a single `results` array, which is
// the half that got missed the first time this was fixed. So the rule is not "append
// each reading" and it is not "append each result": it is that a reading which extends
// the one before it **replaces** it, because they are two readings of the same words.
export default class Transcript {
  constructor() {
    this.chunks = []
    this.session = []
    this.pending = []
  }

  // One `result` event, rebuilt from the whole list rather than appended to — the same
  // result is reported repeatedly as it firms up, so anything that accumulates says the
  // sentence once per update.
  hear(results) {
    this.session = []
    this.pending = []

    for (const result of results) {
      (result.isFinal ? this.session : this.pending).push(result[0].transcript)
    }

    return this.text()
  }

  // A recognition session has ended. Its readings condense to the one sentence it was
  // circling, final and interim together: a session that ends with words still interim
  // would otherwise throw them away, and losing the end of a sentence is worse than
  // assembling one carefully.
  close() {
    this.chunks.push(this.constructor.condense([ ...this.session, ...this.pending ]))
    this.session = []
    this.pending = []
  }

  // Everything heard so far. Sessions are condensed individually and only then joined,
  // which matters: a reading only supersedes another reading of the *same* utterance,
  // and two sessions are two utterances however similar they look.
  text() {
    const live = this.constructor.condense([ ...this.session, ...this.pending ])

    return [ ...this.chunks, live ].reduce((said, piece) => {
      if (piece === "") return said
      if (said === "") return piece

      // A restart can hand back audio the last session already transcribed, either as
      // the tail of what we have or as the whole of it said again.
      if (said.toLowerCase().endsWith(piece.toLowerCase())) return said
      if (piece.toLowerCase().startsWith(said.toLowerCase())) return piece

      return `${said} ${piece}`
    }, "")
  }

  // One session's readings reduced to what it ended up saying. Each reading that starts
  // with the one before it is that reading, grown; anything else is the next thing said.
  static condense(readings) {
    return readings.reduce((said, reading) => {
      const piece = reading.replace(/\s+/g, " ").trim()

      if (piece === "") return said
      if (piece.toLowerCase().startsWith(said.toLowerCase())) return piece

      return said === "" ? piece : `${said} ${piece}`
    }, "")
  }
}
