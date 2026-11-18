#pragma once
#include <stdint.h>
#include "../../../../../Vendor/libmtp/include/libmtp.h"  // vendored, see Vendor/libmtp/README.md

/// Flags from libmtp's src/device-flags.h (not installed by Homebrew).
#define MTT_FLAG_NO_RELEASE_INTERFACE 0x00000040u  /* close skips clear-stall + release */
#define MTT_FLAG_FORCE_RESET_ON_CLOSE 0x10000000u  /* close resets the USB port */

/// Sets the timeout libmtp uses for every USB transfer on this device.
/// Same layout check and return value as mtt_update_device_flags.
int mtt_set_usb_timeout(LIBMTP_mtpdevice_t *device,
                        uint16_t vendor_id, uint16_t product_id,
                        int timeout_ms);

/// Sets then clears bits in the device flags libmtp keeps for an open device:
/// flags = (flags | set) & ~clear.
///
/// libmtp re-applies its Android bug flags while opening, so this has to run
/// after LIBMTP_Open_Raw_Device*. Returns 0 on success, -1 if the private
/// struct layout does not look right (then nothing is written).
int mtt_update_device_flags(LIBMTP_mtpdevice_t *device,
                            uint16_t vendor_id, uint16_t product_id,
                            uint32_t set, uint32_t clear);
