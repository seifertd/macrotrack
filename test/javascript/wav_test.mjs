import { test } from "node:test"
import assert from "node:assert/strict"
import { encodeWav, toMono, wavFrom, SAMPLE_RATE } from "../../app/javascript/lib/wav.js"

const read = (buffer) => new DataView(buffer)
const ascii = (view, offset, length) =>
  String.fromCharCode(...Array.from({ length }, (_, i) => view.getUint8(offset + i)))

test("the header is a wav header whisper.cpp will accept", () => {
  const view = read(encodeWav(new Float32Array(160)))

  assert.equal(ascii(view, 0, 4), "RIFF")
  assert.equal(ascii(view, 8, 4), "WAVE")
  assert.equal(ascii(view, 12, 4), "fmt ")
  assert.equal(ascii(view, 36, 4), "data")
  assert.equal(view.getUint16(20, true), 1, "uncompressed PCM")
  assert.equal(view.getUint16(22, true), 1, "mono")
  assert.equal(view.getUint32(24, true), SAMPLE_RATE)
  assert.equal(view.getUint16(34, true), 16, "16-bit")
})

test("the declared lengths match the bytes actually written", () => {
  const buffer = encodeWav(new Float32Array(1000))
  const view = read(buffer)

  assert.equal(buffer.byteLength, 44 + 2000)
  assert.equal(view.getUint32(40, true), 2000, "data chunk length")
  assert.equal(view.getUint32(4, true), buffer.byteLength - 8, "RIFF length excludes its own 8 bytes")
})

test("samples survive the trip to 16-bit and back", () => {
  const view = read(encodeWav(Float32Array.from([ 0, 1, -1, 0.5 ])))

  assert.equal(view.getInt16(44, true), 0)
  assert.equal(view.getInt16(46, true), 32767, "full positive scale")
  assert.equal(view.getInt16(48, true), -32768, "full negative scale")
  assert.equal(view.getInt16(50, true), 16384)
})

test("a sample past full scale saturates rather than wrapping", () => {
  // Wrapping turns the loudest moment of a sentence into a click, and nothing upstream
  // guarantees the decoder hands back samples inside the range.
  const view = read(encodeWav(Float32Array.from([ 1.4, -1.4 ])))

  assert.equal(view.getInt16(44, true), 32767)
  assert.equal(view.getInt16(46, true), -32768)
})

test("two channels are mixed, not halved", () => {
  const left = Float32Array.from([ 1, 0, 0.5 ])
  const right = Float32Array.from([ 0, 1, 0.5 ])

  assert.deepEqual(Array.from(toMono([ left, right ], 3)), [ 0.5, 0.5, 0.5 ])
})

test("one channel is passed through untouched", () => {
  const mono = Float32Array.from([ 0.25, -0.25 ])

  assert.equal(toMono([ mono ], 2), mono, "no copy, no arithmetic")
})

test("an AudioBuffer converts whole, at its own rate", () => {
  const audioBuffer = {
    numberOfChannels: 2,
    length: 4,
    sampleRate: 16000,
    getChannelData: (i) => (i === 0 ? Float32Array.from([ 1, 0, 0, 0 ]) : Float32Array.from([ 0, 1, 0, 0 ]))
  }

  const view = read(wavFrom(audioBuffer))

  assert.equal(view.getUint32(24, true), 16000)
  assert.equal(view.getUint32(40, true), 8, "four frames, two bytes each")
  assert.equal(view.getInt16(44, true), 16384, "averaged, not taken from one side")
})
