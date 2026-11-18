# Vendored libmtp + libusb

- **libmtp 1.1.23, built from source with two small patches**
  ([patches/libmtp-1.1.23-mtt.patch](patches/libmtp-1.1.23-mtt.patch)):
  - `USB_START_TIMEOUT` 5000 → 1500 ms (500 was tried: too short, the retry then gave a session that did not answer). The first OpenSession after a USB reset
    (e.g. after cancelling a transfer) always times out; this cut the recovery
    from ~10 s to the time measured in PLAN.md.
  - Android devices no longer get `DEVICE_FLAG_FORCE_RESET_ON_CLOSE` (on macOS
    the reset made the phone drop off USB after every close). `CMTPShim` also
    clears it at runtime, so either one alone is enough.
- **libusb 1.0.30**, copied from Homebrew.

Rebuild libmtp with `scripts/build-libmtp.sh <libmtp-1.1.23.tar.gz>` (the tarball
comes from `brew fetch --build-from-source libmtp`; needs `pkg-config`).

Install names are `@rpath/...`; the app embeds both dylibs in
`Contents/Frameworks` and Xcode re-signs them. `CMTPShim` mirrors libmtp
1.1.23's private `PTP_USB` struct, so the version is pinned on purpose.

Both libraries are LGPL-2.1 (see `licenses/`) and are linked dynamically.
