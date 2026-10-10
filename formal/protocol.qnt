// Shell of the protocol state machine: just enough structure for the
// verification toolchain to compile and check end to end. The real
// connection state machine and its invariants are filled in on top of
// this skeleton.
//
// Toolchain: quint 0.33.0 (Apache-2.0) against the Apalache 0.62.1
// server that quint manages under ~/.quint/. A Java 17+ runtime must
// be on PATH. Reproduce:
//
//   npm install -g @informalsystems/quint@0.33.0
//   ~/.quint/apalache-dist-0.62.1/apalache/bin/apalache-mc server --port=8822 &
//   quint verify --init=init --step=step --invariant=inv formal/protocol.qnt
//
// The server step is not optional on Windows under Node 18.20+ or
// 20.12+/21.7+: there the runtime forbids spawning the .bat launcher
// outside a shell, so quint cannot start Apalache itself and reuses a
// running instance instead. On other setups the single verify command
// above starts the server on its own.
//
// If the automatic download is ever interrupted, delete the
// ~/.quint/apalache-dist-0.62.1 tree and unpack the v0.62.1 release
// tarball there instead, after checking it against the release's
// sha256sum.txt: a killed fetch leaves a truncated jar that only
// fails once the server starts.
module protocol {
  // Stand-in state: a monotone counter the checker can reason about.
  var count: int

  // Start the counter at zero.
  action init = count' = 0

  // Advance by one.
  action step = count' = count + 1

  // Trivial safety property: the counter never goes negative.
  val inv = count >= 0
}
