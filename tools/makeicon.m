// SPDX-License-Identifier: MIT
// OpenV7 app-icon renderer. Draws a motorized turntable/vinyl deck on a
// graphite squircle with a cobalt label and a cyan "motion" arc.
//   clang -fobjc-arc -framework Cocoa tools/makeicon.m -o build/makeicon
//   build/makeicon build/icon_1024.png
#import <Cocoa/Cocoa.h>

static NSColor *hex(int r,int g,int b,double a){ return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a]; }

int main(int argc, const char **argv) {
    @autoreleasepool {
        const int S = 1024;
        NSString *out = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"icon_1024.png";
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];

        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:g];

        // transparent canvas
        [[NSColor clearColor] setFill];
        NSRectFillUsingOperation(NSMakeRect(0,0,S,S), NSCompositingOperationCopy);

        CGFloat c = S/2.0;

        // --- squircle background (graphite gradient) ---
        NSRect box = NSMakeRect(84, 84, S-168, S-168);
        NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:box xRadius:200 yRadius:200];
        NSGradient *bg = [[NSGradient alloc] initWithStartingColor:hex(28,36,49,1) endingColor:hex(10,13,19,1)];
        [bg drawInBezierPath:sq angle:-90];

        // soft top sheen
        [NSGraphicsContext saveGraphicsState];
        [sq addClip];
        NSGradient *sheen = [[NSGradient alloc] initWithStartingColor:hex(255,255,255,0.10) endingColor:hex(255,255,255,0.0)];
        [sheen drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c-460, c+40, 920, 620)] angle:-90];
        [NSGraphicsContext restoreGraphicsState];

        // hairline rim
        [hex(120,150,200,0.18) setStroke];
        sq.lineWidth = 3; [sq stroke];

        // --- motion arc (cyan) behind the platter ---
        [NSGraphicsContext saveGraphicsState];
        NSShadow *glow = [NSShadow new];
        glow.shadowColor = hex(76,201,255,0.55); glow.shadowBlurRadius = 26; glow.shadowOffset = NSMakeSize(0,0);
        [glow set];
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(c,c) radius:372 startAngle:158 endAngle:328];
        arc.lineWidth = 24; arc.lineCapStyle = NSLineCapStyleRound;
        [hex(76,201,255,1) setStroke]; [arc stroke];
        [NSGraphicsContext restoreGraphicsState];

        // --- vinyl platter ---
        NSRect disc = NSMakeRect(c-330, c-330, 660, 660);
        NSBezierPath *vinyl = [NSBezierPath bezierPathWithOvalInRect:disc];
        NSGradient *vg = [[NSGradient alloc] initWithStartingColor:hex(24,24,28,1) endingColor:hex(8,8,11,1)];
        [vg drawInBezierPath:vinyl relativeCenterPosition:NSMakePoint(-0.25,0.25)];

        // groove rings
        [hex(60,66,80,0.55) setStroke];
        for (CGFloat r = 312; r > 150; r -= 20) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c-r, c-r, 2*r, 2*r)];
            ring.lineWidth = 2.2; [ring stroke];
        }

        // --- cobalt label ---
        NSRect label = NSMakeRect(c-132, c-132, 264, 264);
        NSGradient *lg = [[NSGradient alloc] initWithStartingColor:hex(47,139,255,1) endingColor:hex(10,86,214,1)];
        [lg drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:label] angle:-70];
        [hex(0,0,0,0.18) setStroke];
        NSBezierPath *lstroke = [NSBezierPath bezierPathWithOvalInRect:label]; lstroke.lineWidth = 3; [lstroke stroke];

        // "V7" wordmark
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
        NSDictionary *attr = @{ NSFontAttributeName:[NSFont systemFontOfSize:132 weight:NSFontWeightHeavy],
                                NSForegroundColorAttributeName:[NSColor whiteColor],
                                NSParagraphStyleAttributeName:ps };
        NSString *mark = @"V7";
        NSSize ts = [mark sizeWithAttributes:attr];
        [mark drawInRect:NSMakeRect(c-ts.width/2, c-ts.height/2 - 4, ts.width, ts.height) withAttributes:attr];

        [NSGraphicsContext restoreGraphicsState];

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:out atomically:YES]) { fprintf(stderr, "write failed: %s\n", argv[1]); return 1; }
        fprintf(stderr, "wrote %s (%dx%d)\n", [out UTF8String], S, S);
    }
    return 0;
}
