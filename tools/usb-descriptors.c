/* SPDX-License-Identifier: MIT
 *
 * Print a USB device's descriptors -- interfaces, alt settings, endpoints --
 * the way `lsusb -v` would, for one VID:PID. macOS ships no lsusb.
 *
 * READ-ONLY. It never opens, claims or configures the device: libusb serves
 * the descriptors from the OS's cache. Safe to run while the bridge is running.
 *
 * This is how the NS7 (15e4:0071) was shown to share the V7's endpoint layout,
 * which is why the bridge drives it unchanged. See docs/NS7-CONTROL-MAP.md.
 *
 *   clang $(pkg-config --cflags --libs libusb-1.0) tools/usb-descriptors.c -o build/usb-descriptors
 *   build/usb-descriptors 15e4 0071      # NS7
 *   build/usb-descriptors 15e4 0075      # V7
 */
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>

static const char *xfer_type(int t) {
    return t == 0 ? "control" : t == 1 ? "iso" : t == 2 ? "bulk" : "interrupt";
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s <vid-hex> <pid-hex>\n", argv[0]); return 2; }
    int vid = (int)strtol(argv[1], NULL, 16), pid = (int)strtol(argv[2], NULL, 16);

    libusb_context *ctx;
    if (libusb_init(&ctx) < 0) { fprintf(stderr, "libusb init failed\n"); return 1; }
    libusb_device **list;
    ssize_t n = libusb_get_device_list(ctx, &list);
    int found = 0;

    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) != 0) continue;
        if (d.idVendor != vid || d.idProduct != pid) continue;
        found = 1;
        printf("device %04x:%04x bcdUSB %04x bcdDevice %04x class %02x/%02x/%02x "
               "maxpkt0 %d configs %d speed %d\n",
               d.idVendor, d.idProduct, d.bcdUSB, d.bcdDevice, d.bDeviceClass,
               d.bDeviceSubClass, d.bDeviceProtocol, d.bMaxPacketSize0,
               d.bNumConfigurations, libusb_get_device_speed(list[i]));

        for (int ci = 0; ci < d.bNumConfigurations; ci++) {
            struct libusb_config_descriptor *cfg;
            if (libusb_get_config_descriptor(list[i], (uint8_t)ci, &cfg) != 0) continue;
            printf(" config %d: %d interfaces, attr %02x, maxpower %dmA\n",
                   cfg->bConfigurationValue, cfg->bNumInterfaces, cfg->bmAttributes,
                   cfg->MaxPower * 2);
            for (int ii = 0; ii < cfg->bNumInterfaces; ii++) {
                const struct libusb_interface *it = &cfg->interface[ii];
                for (int a = 0; a < it->num_altsetting; a++) {
                    const struct libusb_interface_descriptor *id = &it->altsetting[a];
                    printf("  IF%d alt%d class %02x/%02x/%02x  %d endpoints  extra %d B\n",
                           id->bInterfaceNumber, id->bAlternateSetting, id->bInterfaceClass,
                           id->bInterfaceSubClass, id->bInterfaceProtocol,
                           id->bNumEndpoints, id->extra_length);
                    for (int e = 0; e < id->bNumEndpoints; e++) {
                        const struct libusb_endpoint_descriptor *ep = &id->endpoint[e];
                        printf("    EP 0x%02x %-3s %-9s maxpkt %4d (mult %d) interval %d\n",
                               ep->bEndpointAddress,
                               (ep->bEndpointAddress & 0x80) ? "IN" : "OUT",
                               xfer_type(ep->bmAttributes & 3),
                               ep->wMaxPacketSize & 0x7ff,
                               ((ep->wMaxPacketSize >> 11) & 3) + 1, ep->bInterval);
                    }
                }
            }
            libusb_free_config_descriptor(cfg);
        }
    }
    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    if (!found) { fprintf(stderr, "no device %04x:%04x attached\n", vid, pid); return 1; }
    return 0;
}
