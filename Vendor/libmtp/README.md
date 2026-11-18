# Vendored libmtp + libusb

Copied from Homebrew (libmtp 1.1.23, libusb 1.0.30) so the app doesn't break
when Homebrew upgrades them. `CMTPShim` mirrors libmtp 1.1.23's private
`PTP_USB` struct, so the version is pinned on purpose.

Install names were changed to `@rpath/...` and the dylibs re-signed ad hoc
(Xcode re-signs them with the team identity when embedding):

    install_name_tool -id @rpath/libmtp.9.dylib lib/libmtp.9.dylib
    install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib @rpath/libusb-1.0.0.dylib lib/libmtp.9.dylib
    install_name_tool -id @rpath/libusb-1.0.0.dylib lib/libusb-1.0.0.dylib
    codesign --force --sign - lib/*.dylib

Both libraries are LGPL-2.1 (see `licenses/`); they are linked dynamically.
