name = "guangyiliushan/mortarmq"

version = "0.1.0"

// Async runtime pin. 0.20.2 is the version the browser JS backend is verified against.
// Property-test pin: moonbitlang/core/quickcheck ships inside the moon
// toolchain, so the toolchain is what pins it -- moon 0.1.20260920 bundles
// moonbitlang/core 0.10.14+7d59c7ec9. moon.mod cannot pin core ("moon.mod
// only supports versioned registry dependencies in import"; the registry has
// no moonbitlang/core). Upgrading moon upgrades core with it.
import {
  "moonbitlang/async@0.20.2",
}

readme = "README.md"

repository = "https://github.com/guangyiliushan/mortarmq"

license = "BSD-3-Clause"

keywords = [ "mq", "message-queue", "broker" ]

description = "A message queue written natively in MoonBit: wire-protocol access, produce/consume, partitioned topics, at-least-once delivery with DLQ handling, and durable crash recovery"

// The server runs on the native target; client passes an explicit --target when it needs another backend.

preferred_target = "native"
