## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements an asynchronous buffer stream
## which emulates physical async IO.
##
## The stream is based on the standard library's `Deque`,
## which is itself based on a ring buffer.
##
## It works by exposing a regular LPStream interface and
## a method ``pushTo`` to push data to the internal read
## buffer; as well as a handler that can be registered
## that gets triggered on every write to the stream. This
## allows using the buffered stream as a sort of proxy,
## which can be consumed as a regular LPStream but allows
## injecting data for reads and intercepting writes.
##
## Another notable feature is that the stream is fully
## ordered and asynchronous. Reads are queued up in order
## and are suspended when not enough data available. This
## allows preserving backpressure while maintaining full
## asynchrony. Both writing to the internal buffer with
## ``pushTo`` as well as reading with ``read*` methods,
## will suspend until either the amount of elements in the
## buffer goes below ``maxSize`` or more data becomes available.

import stew/byteutils
import chronos, chronicles, metrics
import ../stream/connection
import ./streamseq

when chronicles.enabledLogLevel == LogLevel.TRACE:
  import oids

export connection

logScope:
  topics = "bufferstream"

const
  DefaultBufferSize* = 102400

const
  BufferStreamTrackerName* = "libp2p.bufferstream"

type
  BufferStreamTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupBufferStreamTracker(): BufferStreamTracker {.gcsafe.}

proc getBufferStreamTracker(): BufferStreamTracker {.gcsafe.} =
  result = cast[BufferStreamTracker](getTracker(BufferStreamTrackerName))
  if isNil(result):
    result = setupBufferStreamTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = "Opened buffers: " & $tracker.opened & "\n" &
           "Closed buffers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = (tracker.opened != tracker.closed)

proc setupBufferStreamTracker(): BufferStreamTracker =
  result = new BufferStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(BufferStreamTrackerName, result)

type
  BufferStream* = ref object of Connection
    readQueue*: AsyncQueue[seq[byte]] # read queue for managing backpressure
    readBuf: StreamSeq                # overflow buffer for readOnce

  NotWritableError* = object of CatchableError

proc newNotWritableError*(): ref CatchableError {.inline.} =
  result = newException(NotWritableError, "stream is not writable")

proc len*(s: BufferStream): int =
  s.readBuf.len + (if s.readQueue.len > 0: s.readQueue[0].len() else: 0)

method initStream*(s: BufferStream) =
  if s.objName.len == 0:
    s.objName = "BufferStream"

  procCall Connection(s).initStream()
  inc getBufferStreamTracker().opened

proc initBufferStream*(s: BufferStream) =
  s.readQueue = newAsyncQueue[seq[byte]](1)

  s.initStream()

  trace "created bufferstream", oid = $s.oid

proc newBufferStream*(timeout: Duration = DefaultConnectionTimeout): BufferStream =
  new result
  result.timeout = timeout
  result.initBufferStream()

proc pushTo*(s: BufferStream, data: seq[byte]) {.async.} =
  ## Write bytes to internal read buffer, use this to fill up the
  ## buffer with data.
  ##
  ## This method is async and will wait until all data has been
  ## written to the internal buffer; this is done so that backpressure
  ## is preserved.
  ##

  if s.isClosed:
    raise newLPStreamEOFError()

  if data.len == 0:
    return

  # We will block here if there is already data queued, until it has been
  # processed
  await s.readQueue.addLast(data)

method readOnce*(s: BufferStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  logScope: oid = $s.oid

  if s.isEof and s.readBuf.len() == 0:
    raise newLPStreamEOFError()

  var
    p = cast[ptr UncheckedArray[byte]](pbytes)

  # First consume leftovers from previous read
  var size = s.readBuf.consumeTo(toOpenArray(p, 0, nbytes - 1))

  if size < nbytes:
    # There's space in the buffer - consume some data from the read queue
    trace "readQueue"
    let buf = await s.readQueue.popFirst()
    s.activity = true

    if buf.len == 0:
      # No more data will arrive on read queue
      s.isEof = true
    else:
      let remaining = min(buf.len, nbytes - size)
      toOpenArray(p, size, nbytes - 1)[0..<remaining] = buf[0..<remaining]
      size += remaining

      if remaining < buf.len:
        trace "add leftovers", len = buf.len - remaining
        s.readBuf.add(buf.toOpenArray(remaining, buf.high))

  if s.isEof and s.readBuf.len() == 0:
    # We can clear the readBuf memory since it won't be used any more
    s.readBuf = StreamSeq()

  return size

method close*(s: BufferStream) {.async, gcsafe.} =
  try:
    ## close the stream and clear the buffer
    if not s.isClosed:
      trace "closing bufferstream", oid = $s.oid

      # Push empty block to signal close, but don't block
      asyncCheck s.readQueue.addLast(@[])

      await procCall Connection(s).close()
      inc getBufferStreamTracker().closed
      trace "bufferstream closed", oid = $s.oid
    else:
      trace "attempt to close an already closed bufferstream",
        trace = getStackTrace(), oid = $s.oid
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error closing buffer stream", exc = exc.msg
