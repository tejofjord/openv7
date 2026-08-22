/* SPDX-License-Identifier: MIT
 *
 * OpenV7 — App-Nap / QoS-clamp exemption for the bridge process.
 *
 * A menu-bar (LSUIElement) app is a "background" app; macOS clamps the QoS of
 * that app's coalition — including any NSTask child it spawns. The bridge then
 * still runs, but at a throttled QoS with aggressive timer coalescing, which
 * jitters the isochronous USB clock enough that the Ploytec device underruns
 * and stops streaming its control surface (jog/platter/buttons go silent).
 *
 * A process that holds a LatencyCritical activity assertion is exempt from that
 * clamp. The assertion is per-process, so the parent app holding one does NOT
 * cover this child — the bridge must assert for itself. We take the assertion
 * once at startup and hold it for the whole process lifetime.
 *
 * Compiled as Objective-C (Foundation) and linked into the otherwise-C bridge.
 */
#import <Foundation/Foundation.h>

/* Retained for the whole process lifetime; intentionally never released. MRC
   (this file is built without -fobjc-arc), so retain explicitly and keep the
   begin/end assertion balanced-by-never-ending. */
static id g_activity;

void openv7_prevent_appnap(void) {
    @autoreleasepool {
        g_activity = [[[NSProcessInfo processInfo]
            beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical)
                              reason:@"OpenV7 USB isochronous streaming"] retain];
    }
}
