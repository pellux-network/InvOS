# Changelog

## [1.1.0](https://github.com/pellux-network/InvOS/compare/v1.0.1...v1.1.0) (2026-08-18)


### Features

* **emulator:** craft through an emulated turtle ([15a6c9f](https://github.com/pellux-network/InvOS/commit/15a6c9f8e1492f488bbcecfee011286723a31e4e))


### Performance Improvements

* **storage:** make transfer latency independent of node count ([f643dca](https://github.com/pellux-network/InvOS/commit/f643dcae8345190e5de4715c7849e8848af59502))

## [1.0.1](https://github.com/pellux-network/InvOS/compare/v1.0.0...v1.0.1) (2026-08-16)


### Bug Fixes

* give the "real pack" craft tests their own vanilla fixture ([18b1355](https://github.com/pellux-network/InvOS/commit/18b13557ea2267c29332e7d9ab2698badcb0a824))
* update the stale manifest file-count assertion ([1c2d625](https://github.com/pellux-network/InvOS/commit/1c2d625db5c3dd1e2b242ea35fe076e95055bd40))

## 1.0.0 (2026-08-15)

Initial public release. Search-first storage terminal for CC:Tweaked, with pooled
NBT-aware indexing, exact retrieval, and optional multi-step crafting via a stationary
crafty turtle. Includes a one-line installer (`wget run install.lua`) and in-app
self-update for both the controller and the crafting turtle.
