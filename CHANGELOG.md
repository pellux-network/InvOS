# Changelog

## [1.1.0](https://github.com/pellux-network/InvOS/compare/v1.0.0...v1.1.0) (2026-08-15)


### Features

* **coordinator:** wire the updater into the event/work loop ([e27ae8b](https://github.com/pellux-network/InvOS/commit/e27ae8bea3d10587a5ac010010b6c9408ff69914))
* **deploy:** write version.txt to the live tree ([8f83c14](https://github.com/pellux-network/InvOS/commit/8f83c14f0985793e4979740659f99984f1f9b2bf))
* **install:** add install.lua's fetch/verify/write/reboot flow ([9e36186](https://github.com/pellux-network/InvOS/commit/9e36186ed902e93e3a423290410f0ceef6620b7d))
* **main:** read /version.txt at boot and construct the updater ([87cdba1](https://github.com/pellux-network/InvOS/commit/87cdba162b9287bb75bbdb10d29c879f253fe10d))
* **turtle:** ack an update command in the executor ([53005c1](https://github.com/pellux-network/InvOS/commit/53005c1f57ca8899baaacd71aa5c5926b1f8d027))
* **turtle:** fetch and run install.lua on an update command ([16f3b5d](https://github.com/pellux-network/InvOS/commit/16f3b5df42c106c53b1f5a216f5e2eb434480037))
* **ui:** add the update-confirm and turtle-unreachable armed states ([78378ff](https://github.com/pellux-network/InvOS/commit/78378ff7b8cc016ea2408fefa157efc78af041cd))
* **ui:** show the running version in the header ([3eaa0cd](https://github.com/pellux-network/InvOS/commit/3eaa0cd11740bd60f612d26bbf912d4cc5de7b12))
* **updater:** add the version-check and update-trigger module ([08f4aec](https://github.com/pellux-network/InvOS/commit/08f4aec90ae1e241bf33a69132ccc519546ea7cf))

## 1.0.0 (2026-08-15)

Initial public release.
