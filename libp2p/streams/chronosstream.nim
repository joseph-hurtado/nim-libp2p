## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import stream, ringbuffer

logScope:
  topic = "ChronosStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type ChronosStream* = ref object of Stream
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport
    buffer: seq[byte]
    maxChunkSize: int

proc init*(C: type[ChronosStream],
           server: StreamServer,
           client: StreamTransport,
           maxChunkSize = DefaultChunkSize): C =

  ChronosStream(server: server,
                client: client,
                reader: newAsyncStreamReader(client),
                writer: newAsyncStreamWriter(client),
                maxChunkSize: maxChunkSize,
                buffer: newSeq[byte](maxChunkSize))

proc internalRead(c: ChronosStream): Future[seq[byte]] {.async.} =
  var buff = newSeq[byte](1024)
  var read = await c.reader.readOnce(unsafeAddr buff[0], buff.len)
  result = buff[0..<read]

method source*(c: ChronosStream): Source[seq[byte]] =
  return iterator(): Future[seq[byte]] =
    while not c.reader.atEof():
      yield c.internalRead()

method sink*(c: ChronosStream): Sink[seq[byte]] =
  return proc(i: Source[seq[byte]]) {.async.} =
    for chunk in i:
      if c.closed:
        break

      # sadly `await c.writer.write((await chunk))` breaks
      var cchunk = await chunk
      await c.writer.write(cchunk)

method close*(c: ChronosStream) {.async.} =
  if not c.closed:
    trace "shutting chronos stream", address = $c.client.remoteAddress()
    if not c.writer.closed():
      await c.writer.closeWait()

    if not c.reader.closed():
      await c.reader.closeWait()

    if not c.client.closed():
      await c.client.closeWait()

  c.isClosed = true

method atEof*(c: ChronosStream): bool =
  c.reader.atEof()