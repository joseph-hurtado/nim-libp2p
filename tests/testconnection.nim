import unittest
import chronos, nimcrypto/utils
import ../libp2p/[stream/connection,
                  stream/bufferstream]

suite "Connection":
  test "close":
    proc test(): Future[bool] {.async.} =
      var conn = newBufferStream()
      await conn.close()
      check:
        conn.closed == true

      result = true

    check:
      waitFor(test()) == true

  test "parent close":
    proc test(): Future[bool] {.async.} =
      var buf = newBufferStream()
      var conn = buf

      await conn.close()
      check:
        conn.closed == true
        buf.closed == true

      await sleepAsync(1.seconds)
      result = true

    check:
      waitFor(test()) == true

  test "child close":
    proc test(): Future[bool] {.async.} =
      var buf = newBufferStream()
      var conn = buf

      await buf.close()
      check:
        conn.closed == true
        buf.closed == true

      await sleepAsync(1.seconds)
      result = true

    check:
      waitFor(test()) == true
