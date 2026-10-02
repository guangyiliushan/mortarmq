name = "guangyiliushan/mortarmq"

version = "0.1.0"

// Async runtime pin. 0.20.2 is the version the browser JS backend is verified against.
import {
  "moonbitlang/async@0.20.2",
}

readme = "README.md"

repository = "https://github.com/guangyiliushan/mortarmq"

license = "BSD-3-Clause"

keywords = [ "mq", "message-queue", "broker" ]

description = "A message queue written natively in MoonBit: wire-protocol access, produce/consume, partitioned topics, at-least-once delivery with DLQ handling, and durable crash recovery"

// The server runs on the native target; bench and client pass an explicit --target when they need another backend.

preferred_target = "native"
