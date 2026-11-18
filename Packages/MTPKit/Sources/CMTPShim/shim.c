#include "mtt_shim.h"
#include <string.h>

/*
 * Mirror of struct _PTP_USB from libmtp 1.1.23 src/libusb-glue.h, built with
 * libusb-1.0 (HAVE_LIBUSB1), which is how Homebrew builds it. The header is
 * private, so the layout is copied here and checked at runtime before use.
 */
typedef struct {
  void *params;
  void *handle;
  uint8_t config;
  uint8_t interface;
  uint8_t altsetting;
  int inep;
  int inep_maxpacket;
  int outep;
  int outep_maxpacket;
  int intep;
  int callback_active;
  int timeout;
  uint16_t bcdusb;
  uint64_t current_transfer_total;
  uint64_t current_transfer_complete;
  LIBMTP_progressfunc_t current_transfer_callback;
  void const *current_transfer_callback_data;
  LIBMTP_raw_device_t rawdevice;
} mtt_ptp_usb_mirror;

/* Returns libmtp's private USB state, or NULL if the layout doesn't check out. */
static mtt_ptp_usb_mirror *usb_state(LIBMTP_mtpdevice_t *device,
                                     uint16_t vendor_id, uint16_t product_id)
{
  if (device == NULL || device->usbinfo == NULL) return NULL;
  if (strcmp(LIBMTP_VERSION_STRING, "1.1.23") != 0) return NULL;

  mtt_ptp_usb_mirror *usb = (mtt_ptp_usb_mirror *)device->usbinfo;
  /* If the layout is wrong these won't match the device we opened. */
  if (usb->params != device->params) return NULL;
  if (usb->rawdevice.device_entry.vendor_id != vendor_id) return NULL;
  if (usb->rawdevice.device_entry.product_id != product_id) return NULL;
  return usb;
}

int mtt_update_device_flags(LIBMTP_mtpdevice_t *device,
                            uint16_t vendor_id, uint16_t product_id,
                            uint32_t set, uint32_t clear)
{
  mtt_ptp_usb_mirror *usb = usb_state(device, vendor_id, product_id);
  if (usb == NULL) return -1;
  uint32_t flags = usb->rawdevice.device_entry.device_flags;
  usb->rawdevice.device_entry.device_flags = (flags | set) & ~clear;
  return 0;
}

int mtt_set_usb_timeout(LIBMTP_mtpdevice_t *device,
                        uint16_t vendor_id, uint16_t product_id,
                        int timeout_ms)
{
  mtt_ptp_usb_mirror *usb = usb_state(device, vendor_id, product_id);
  if (usb == NULL) return -1;
  usb->timeout = timeout_ms;
  return 0;
}
