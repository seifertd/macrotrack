// What the recogniser said, assembled (WP5-a).
//
// Split out of dictation_controller because it is the half with a right answer: given a
// sequence of `result` events it produces one sentence, and that can be checked without
// a microphone, a browser, or a person willing to say "magic juice" into a phone. The
// controller keeps the parts that genuinely need a device — permissions, timers, the
// recogniser's own lifecycle — and this keeps the parts that don't.
//
// Every rule here was learned from one recording on 22 August, which came out as
// "I'mI'm going toI'm going to haveI'm going to have…".
export default class Transcript {
  constructor() {
    this.chunks = []
    this.session = ""
    this.pending = ""
  }

  // One `result` event. Rebuilt from the whole list every time, never appended to:
  // Chrome on Android reports the same result over and over as it firms up, each report
  // a longer prefix of the same sentence, so anything that appends says the sentence
  // once per update. Recomputing is idempotent, which is the property that matters.
  hear(results) {
    let final = ""
    let interim = ""

    for (const result of results) {
      if (result.isFinal) final += `${result[0].transcript} `
      else interim += `${result[0].transcript} `
    }

    this.session = final
    this.pending = interim

    return this.text(final, interim)
  }

  // A recognition session has ended. Both halves are kept, and in this order: stop()
  // normally finalises whatever it was in the middle of, but a session that ends with
  // words still interim would otherwise throw them away, and losing the end of a
  // sentence is worse than assembling one carefully.
  close() {
    this.chunks.push(this.session, this.pending)
    this.session = ""
    this.pending = ""
  }

  // Everything heard so far, in order, with a piece dropped where it only repeats what
  // is already there. Rebuilding in `hear` handles duplicates inside one session; this
  // handles the seam between two, because restarting mid-utterance can hand back audio
  // the previous session already transcribed.
  text(...parts) {
    return [ ...this.chunks, ...parts ].reduce((said, part) => {
      const piece = part.replace(/\s+/g, " ").trim()

      if (piece === "" || said.toLowerCase().endsWith(piece.toLowerCase())) return said

      return said === "" ? piece : `${said} ${piece}`
    }, "")
  }
}
