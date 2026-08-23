// SPDX-License-Identifier: MIT
//
// OpenV7.app — menu-bar app + native tester for the Numark V7.
//
// Runs the bundled `openv7-bridge` (which publishes the "Numark V7" CoreMIDI
// device), and provides a native AppKit tester window that observes that MIDI
// to light up a device diagram, learn the control map, log messages, and send
// motor/LED test commands. Also a calibration walkthrough. No browser.

#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#import <ServiceManagement/ServiceManagement.h>
#import <signal.h>
#import <IOKit/IOKitLib.h>

/* Is the V7 physically on the USB bus right now?

   Asked straight of IOKit rather than inferred from the bridge: the bridge is a
   child process on a 3 s relaunch cycle, so "is the bridge up" lags reality by
   seconds and reports nothing at all during the window where it has exited and
   not yet been restarted. Calibration gates on this answer, and a gate that
   says "unplugged" for three seconds after you plugged the cable back in is
   worse than no gate. IOKit is synchronous and current. */
static BOOL v7IsPluggedIn(void) {
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    if(!m) return NO;
    int vid=0x15E4, pid=0x0075;                       /* Numark V7 — see src/ploytec.h */
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vid);
    CFNumberRef p=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFDictionarySetValue(m,CFSTR("idVendor"),v);
    CFDictionarySetValue(m,CFSTR("idProduct"),p);
    CFRelease(v); CFRelease(p);
    io_iterator_t it=0;
    /* IOServiceGetMatchingServices CONSUMES m — do not release it here. */
    if(IOServiceGetMatchingServices(kIOMainPortDefault,m,&it)!=KERN_SUCCESS) return NO;
    BOOL found=NO; io_object_t o;
    while((o=IOIteratorNext(it))){ found=YES; IOObjectRelease(o); }
    IOObjectRelease(it);
    return found;
}

static NSColor *HEX(int r,int g,int b,double a){ return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a]; }

// ============================================================ V7Control
@interface V7Control : NSObject
@property (copy) NSString *cid, *label, *kind;
@property NSRect frac;                 // x,y,w,h in 0..1 (top-left origin)
@property CFTimeInterval hitUntil;     // glow deadline
@property int lastVal;                 // for faders/strip position
@property BOOL hasMap; @property uint8_t status, d0;
/* Deck-B address. The V7 addresses the two decks separately (deck B = deck A
   + 0x21 for notes; CCs are individually assigned) and the DECK SELECT switch
   decides which block the hardware actually emits. A tester must light up on
   EITHER, otherwise the panel is silently dead whenever the switch is on the
   deck the map does not cover -- which is exactly the bug this replaces.
   d0B == 0xFF means "this control has no separate deck-B address". */
@property uint8_t d0B;
/* The shipped defaults, kept separately so "clear map" restores them instead of
   blanking the panel -- loadMap resets to these before applying saved overrides. */
@property BOOL defHasMap; @property uint8_t defStatus, defD0;
@property double knobAngle;             // accumulated angle, relative encoders only
/* Several knobs are ALSO push-buttons (BROWSE loads the track, FX SELECT docks
   the FX GUI). The push is a separate note-on address, unrelated to the CC that
   carries the rotation, so a knob needs both. 0 = this knob does not push.
   Remember: a release is note-on with velocity 0, never note-off 0x80. */
@property uint8_t pressStatus, pressD0, pressD0B;
/* Fader polarity is NOT uniform on this deck: PITCH reports its high value at
   the "+" end, which is physically at the BOTTOM, while FX MIX runs the normal
   way up. One shared convention renders one of them upside down. */
@property BOOL faderInverted;
@property BOOL pressHeld;
@end
@implementation V7Control @end

// ============================================================ DeviceView
@class DeviceView;
@protocol DeviceViewDelegate <NSObject>
- (void)deviceViewDidArm:(V7Control *)c;
@end

@interface DeviceView : NSView
@property (strong) NSMutableArray<V7Control*> *controls;
@property (assign) BOOL learn;
@property (weak) V7Control *armed;
@property (weak) id<DeviceViewDelegate> delegate;
@property (assign) double platterAngle;        // accumulated rotation (radians)
@property (assign) int    platterPos;          // last encoder position (0..127), -1 = none
@property (assign) CFTimeInterval platterSpinUntil;   // "actively spinning" deadline
@property (assign) int    activeDeck;          // 0 = A, 1 = B, tracked from B0 7D
@property (assign) int    revState;            // BLEEP/REVERSE: 0 centre, 1 BLEEP, 2 REVERSE
@end

@implementation DeviceView
- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _controls = [NSMutableArray array];
        /* id, label, x,y,w,h, kind, status, deck-A d0, deck-B d0
           ------------------------------------------------------------------
           Geometry is MEASURED, not estimated: the 41 numbered callouts on the
           VirtualDJ V7 control diagram (500x553) were located by detecting the
           blue badge blobs, and the large elements were measured directly --
           the platter is a true circle, centre (250,284) r=166, and the strip
           and pitch-fader slots were scanned edge to edge. Values below are
           those pixels over 500 / 553, so the panel keeps the real V7's
           proportions (aspect 0.9042) at any window size.

           MIDI addresses come from docs/CONTROL-MAP.md (88/89 inputs measured
           on hardware). -1 = no address. Buttons are note-on 0x90 (a release is
           velocity 0, NEVER note-off 0x80); continuous controls are CC 0xB0.
           ------------------------------------------------------------------ */
        NSArray *L = @[
          @[@"strip",      @"STRIP SEARCH",   @0.34600,@0.03074,@0.30800,@0.03978,@"strip",@176,@69,@77],
          @[@"beatdiff",   @"BEAT DIFF",      @0.42400,@0.10488,@0.16000,@0.02170,@"meter",@0,@-1,@-1],
          @[@"browse",     @"BROWSE",         @0.80400,@0.01447,@0.07200,@0.06510,@"encoder",@176,@68,@-1],
          @[@"loopctl",    @"L.CTRL",   @0.06200,@0.07052,@0.06800,@0.03978,@"btn",@144,@36,@69],
          @[@"loopmode",   @"MODE",      @0.22400,@0.06329,@0.06800,@0.03978,@"btn",@144,@39,@72],
          @[@"loopin",     @"IN",        @0.02200,@0.12658,@0.06800,@0.03978,@"btn",@144,@40,@73],
          @[@"loopout",    @"OUT",       @0.10400,@0.12658,@0.06800,@0.03978,@"btn",@144,@41,@74],
          @[@"loopsel",    @"SEL",         @0.18800,@0.12658,@0.06800,@0.03978,@"btn",@144,@42,@75],
          @[@"reloop",     @"RELP",         @0.27400,@0.12658,@0.06800,@0.03978,@"btn",@144,@43,@76],
          @[@"loophalf",   @"1/2",        @0.02400,@0.18264,@0.06800,@0.03978,@"btn",@144,@34,@67],
          @[@"loopdbl",    @"x2",        @0.10400,@0.18264,@0.06800,@0.03978,@"btn",@144,@35,@68],
          @[@"loopprev",   @"<",         @0.18600,@0.18264,@0.06800,@0.03978,@"btn",@144,@37,@70],
          @[@"loopnext",   @">",         @0.27200,@0.18264,@0.06800,@0.03978,@"btn",@144,@38,@71],
          @[@"back",       @"BACK",           @0.72800,@0.10488,@0.07600,@0.03978,@"btn",@144,@6,@-1],
          @[@"fwd",        @"FWD",            @0.91000,@0.10127,@0.07600,@0.03978,@"btn",@144,@7,@-1],
          @[@"crates",     @"CRATES",         @0.72800,@0.16094,@0.07600,@0.03978,@"btn",@144,@11,@-1],
          @[@"prepare",    @"PREP",        @0.81600,@0.16094,@0.07600,@0.03978,@"btn",@144,@9,@-1],
          @[@"files",      @"FILES",          @0.91000,@0.15913,@0.07600,@0.03978,@"btn",@144,@10,@-1],
          @[@"loada",      @"LOAD A",         @0.72800,@0.20976,@0.07600,@0.03978,@"btn",@144,@12,@-1],
          @[@"loadprep",   @"LD PRP",      @0.81600,@0.20976,@0.07600,@0.03978,@"btn",@144,@13,@-1],
          @[@"loadb",      @"LOAD B",         @0.91000,@0.20796,@0.07600,@0.03978,@"btn",@144,@14,@-1],
          @[@"decksel",    @"DECK",    @0.79600,@0.25678,@0.11200,@0.03978,@"switch",@144,@92,@-1],
          @[@"master",     @"MASTER",       @0.82400,@0.32550,@0.06800,@0.02893,@"btn",@144,@84,@91],
          @[@"motoroff",   @"MOTOR",      @0.10000,@0.26401,@0.08000,@0.03617,@"btn",@144,@33,@66],
          @[@"starttime",  @"START",     @0.19600,@0.24231,@0.05600,@0.05063,@"knob",@176,@70,@78],
          @[@"stoptime",   @"STOP",      @0.14000,@0.32188,@0.05600,@0.05063,@"knob",@176,@71,@79],
          @[@"reverse",    @"BLEEP",      @0.04000,@0.30380,@0.06800,@0.09403,@"switch",@144,@28,@61],
          @[@"tap",        @"TAP",            @0.04000,@0.45570,@0.08800,@0.04340,@"btn",@144,@30,@63],
          @[@"fxsel",      @"FX SEL",      @0.05600,@0.54250,@0.06800,@0.06148,@"encoder",@176,@90,@91],
          @[@"fxparam",    @"FX PRM",       @0.03200,@0.62929,@0.07600,@0.06872,@"encoder",@176,@88,@86],
          @[@"fxmix",      @"FX MIX",         @0.04800,@0.71971,@0.06000,@0.12658,@"fader",@176,@87,@89],
          @[@"fxon",       @"FX ON",      @0.03600,@0.90416,@0.08800,@0.04702,@"btn",@144,@82,@89],
          @[@"platter",    @"JOG",            @0.16800,@0.21338,@0.66400,@0.60036,@"platter",@176,@0,@2],
          @[@"mtempo",     @"M.TEMPO",   @0.87600,@0.40506,@0.08400,@0.04340,@"btn",@144,@27,@60],
          @[@"range",      @"RANGE",          @0.87600,@0.45750,@0.08400,@0.04340,@"btn",@144,@26,@59],
          @[@"pitch",      @"PITCH",          @0.87000,@0.54250,@0.10000,@0.25136,@"fader",@176,@4,@5],
          @[@"bendm",      @"\u2212",         @0.85000,@0.92586,@0.06000,@0.04340,@"btn",@144,@24,@57],
          @[@"bendp",      @"+",         @0.91600,@0.92586,@0.06000,@0.04340,@"btn",@144,@25,@58],
          @[@"delete",     @"DEL",         @0.24000,@0.83906,@0.06400,@0.04340,@"btn",@144,@18,@51],
          @[@"pad1",       @"1",              @0.37200,@0.83906,@0.06600,@0.04340,@"pad",@144,@19,@52],
          @[@"pad2",       @"2",              @0.44600,@0.83906,@0.06600,@0.04340,@"pad",@144,@20,@53],
          @[@"pad3",       @"3",              @0.52000,@0.83906,@0.06600,@0.04340,@"pad",@144,@21,@54],
          @[@"pad4",       @"4",              @0.59400,@0.83906,@0.06600,@0.04340,@"pad",@144,@22,@55],
          @[@"pad5",       @"5",              @0.66800,@0.83906,@0.06600,@0.04340,@"pad",@144,@23,@56],
          @[@"sync",       @"SYNC",           @0.32500,@0.91863,@0.10400,@0.07233,@"big",@144,@15,@48],
          @[@"cue",        @"CUE",            @0.44080,@0.91863,@0.10400,@0.07233,@"big",@144,@16,@49],
          @[@"play",       @"PLAY",           @0.57300,@0.91863,@0.10400,@0.07233,@"big",@144,@17,@50],
        ];
        for (NSArray *a in L) {
            V7Control *c = [V7Control new];
            c.cid=a[0]; c.label=a[1];
            c.frac=NSMakeRect([a[2] doubleValue],[a[3] doubleValue],[a[4] doubleValue],[a[5] doubleValue]);
            c.kind=a[6]; c.lastVal=-1;
            int st=[a[7] intValue], dA=[a[8] intValue], dB=[a[9] intValue];
            if(st && dA>=0){ c.defHasMap=YES; c.defStatus=(uint8_t)st; c.defD0=(uint8_t)dA; }
            c.d0B = (dB>=0) ? (uint8_t)dB : 0xFF;
            [_controls addObject:c];
        }
        /* Knob presses -- MEASURED on this hardware, not inferred. These are
           separate addresses from the rotation CC, so a knob carries both.

           BROWSE push = note 0x08. That also settles an open question in the
           docs, which had 0x08 flagged as "not LOAD PREPARE" with its panel
           label unidentified: it is the browse encoder's push. It has no deck-B
           address because BROWSE is a single shared control, not per-deck (the
           CC table in docs/CONTROL-MAP.md lists 0x44 with an empty deck-B
           column).

           FX SELECT push is a DECK PAIR: 0x53 on deck A, 0x5A on deck B --
           the `0x53 / 0x5A` row of the note table, the same shape as its
           neighbours FX ON (0x52/0x59) and MASTER (0x54/0x5B).

           This previously carried 0x5A alone, in the deck-A slot, with no deck-B
           address at all. 0x5A is the deck-B address, so with the switch on A
           the press emitted 90 53 xx and matched nothing: the knob turned on
           screen but pressing it did nothing, which is exactly the failure the
           deck-pair comment on controlForStatus warns about. Re-measured here:
           press gave `90 53 7f` / `90 53 00` and rotation `b0 5a 7f` with the
           switch on A -- so the old note that rotation is CC 0x5B was the
           deck-B half of that pair too. */
        for(V7Control *c in _controls){
            if([c.cid isEqual:@"browse"]){ c.pressStatus=0x90; c.pressD0=0x08; c.pressD0B=0xFF; }
            if([c.cid isEqual:@"fxsel"]) { c.pressStatus=0x90; c.pressD0=0x53; c.pressD0B=0x5A; }
            if([c.cid isEqual:@"fxmix"])  c.faderInverted=YES;   /* max at the top */
        }
        [self loadMap];
        _platterPos = -1;
    }
    return self;
}

/* The real V7 deck face is 500 x 553 (aspect 0.9042). Laying the fractional
   coordinates out over the raw view bounds would stretch the panel whenever the
   window aspect differs -- the platter would render as an ellipse. Instead fit a
   centred, aspect-correct panel inside the bounds and place everything in that,
   so the proportions stay true at any window size. */
#define V7_PANEL_ASPECT (500.0/553.0)
- (NSRect)panelRect {
    NSRect b=self.bounds;
    CGFloat w=b.size.width, h=w/V7_PANEL_ASPECT;
    if (h > b.size.height) { h=b.size.height; w=h*V7_PANEL_ASPECT; }
    return NSMakeRect(b.origin.x+(b.size.width-w)/2, b.origin.y+(b.size.height-h)/2, w, h);
}
- (NSRect)rectFor:(V7Control*)c {
    NSRect b=[self panelRect];
    return NSMakeRect(b.origin.x + c.frac.origin.x*b.size.width,
                      b.origin.y + c.frac.origin.y*b.size.height,
                      c.frac.size.width*b.size.width, c.frac.size.height*b.size.height);
}

/* Match a control on EITHER deck's address. The hardware only ever emits the
   block the DECK SELECT switch has live, so binding to deck A alone leaves the
   whole panel dark whenever the switch is on B -- the previous behaviour. */
- (V7Control*)controlForStatus:(uint8_t)s d0:(uint8_t)d0 {
    for (V7Control *c in _controls)
        if (c.hasMap && c.status==s && (c.d0==d0 || (c.d0B!=0xFF && c.d0B==d0))) return c;
    return nil;
}

- (V7Control*)controlForPress:(uint8_t)s d0:(uint8_t)d0 {
    for (V7Control *c in _controls)
        if (c.pressStatus && c.pressStatus==s &&
            (c.pressD0==d0 || (c.pressD0B!=0xFF && c.pressD0B==d0))) return c;
    return nil;
}
- (void)flashStatus:(uint8_t)s d0:(uint8_t)d0 d1:(uint8_t)d1 {
    /* B0 7D reports the DECK SELECT position (00 = A, 01 = B). It is not a
       control, so it must be read BEFORE the lookup that returns on no match.
       The platter counter is per-deck, so drop the stale position on a switch
       or the first message after it spins the platter by a bogus delta. */
    if (s==0xB0 && d0==0x7D) {
        int deck = d1 ? 1 : 0;
        if (deck != _activeDeck) { _activeDeck = deck; _platterPos = -1; }
        self.needsDisplay=YES;
    }
    /* A knob's push arrives on its own note address, so it must be looked up
       separately from the rotation CC. Velocity 0 is the RELEASE (the V7 never
       sends note-off 0x80), which is what clears the held state. */
    /* BLEEP / REVERSE is a three-position switch, not a button, and the two
       positions report on SEPARATE notes. MEASURED: 0x1D latches -- it went 7F
       and stayed on for 11.5 s until the switch was moved back, which is the
       persistent REVERSE detent. 0x1C is BLEEP -- also MEASURED now: momentary,
       spring-loaded (the censor), 7F while held and 00 on return.

       BEWARE THE BOUNCE: the BLEEP lever chatters badly on release, up to a
       dozen 7F/00 pairs in a second on one flick. Fine for lighting a lever on
       a panel, but a host that acts on every edge will re-trigger the censor
       repeatedly -- debounce before driving playback with it. */
    if (s==0x90 && (d0==0x1C||d0==0x3D)) { _revState = d1?1:0; self.needsDisplay=YES; }
    if (s==0x90 && (d0==0x1D||d0==0x3E)) { _revState = d1?2:0; self.needsDisplay=YES; }
    V7Control *pc=[self controlForPress:s d0:d0];
    if(pc){ pc.pressHeld=(d1!=0); pc.hitUntil=CFAbsoluteTimeGetCurrent()+0.18;
            self.needsDisplay=YES; return; }
    V7Control *c=[self controlForStatus:s d0:d0]; if(!c) return;
    c.hitUntil = CFAbsoluteTimeGetCurrent()+0.18;
    if ([c.kind isEqual:@"fader"]||[c.kind isEqual:@"strip"]||[c.kind isEqual:@"knob"]) c.lastVal=d1;
    /* Relative encoders report DIRECTION, not position: 0x01 = one detent
       clockwise, 0x7F = one anticlockwise (docs/HANDOFF-MAC.md). Treating that
       value as an absolute position would peg the pointer at one end. */
    if ([c.kind isEqual:@"encoder"]) c.knobAngle += ((d1 > 64) ? -1 : 1) * (2*M_PI/32.0);
    if ([c.kind isEqual:@"platter"]) {
        if (_platterPos >= 0) {
            int delta = (int)d1 - _platterPos;        // signed shortest path on the 0..127 ring
            if (delta > 64) delta -= 128; else if (delta < -64) delta += 128;
            /* SIGN: this view isFlipped (y grows downward), so a POSITIVE angle
               passed to rotateByRadians: renders CLOCKWISE -- the opposite of the
               usual unflipped convention. The encoder counts up as the platter
               turns forward/clockwise, so the angle must ADD. Subtracting (the
               previous behaviour) spun the on-screen platter backwards.

               SCALE: the platter is a measured 3600 counts/rev (PROTOCOL.md), so
               2*pi/3600 per count tracks the real platter 1:1. The previous 1024
               was a placeholder marked "tunable" and span the GUI ~3.5x too fast. */
            _platterAngle += delta * (2*M_PI/3600.0);
        }
        _platterPos = d1;
        _platterSpinUntil = CFAbsoluteTimeGetCurrent() + 0.30;
    }
    self.needsDisplay=YES;
}

- (BOOL)bindArmedToStatus:(uint8_t)s d0:(uint8_t)d0 {
    if(!_learn || !_armed) return NO;
    _armed.hasMap=YES; _armed.status=s; _armed.d0=d0;
    _armed=nil; [self saveMap]; self.needsDisplay=YES; return YES;
}

- (void)mouseDown:(NSEvent*)e {
    NSPoint p=[self convertPoint:e.locationInWindow fromView:nil];
    for (V7Control *c in _controls) if (NSPointInRect(p,[self rectFor:c])) {
        if(!_learn) return;
        _armed = (_armed==c)?nil:c; self.needsDisplay=YES;
        if(_armed && [self.delegate respondsToSelector:@selector(deviceViewDidArm:)]) [self.delegate deviceViewDidArm:_armed];
        return;
    }
}

- (void)drawRoundRect:(NSRect)r radius:(CGFloat)rad fill:(NSColor*)f stroke:(NSColor*)s width:(CGFloat)w {
    NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    if(f){[f setFill];[p fill];} if(s){[s setStroke];p.lineWidth=w;[p stroke];}
}
- (void)label:(NSString*)t in:(NSRect)r color:(NSColor*)col size:(CGFloat)sz {
    if(!t.length) return;
    NSMutableParagraphStyle *ps=[NSMutableParagraphStyle new]; ps.alignment=NSTextAlignmentCenter;
    /* Shrink to fit. drawInRect: silently CLIPS overflow, which is how the panel
       ended up showing "LOOP" for LOOP CONTROL, "SELEC" for SELECT and "PREPA"
       for PREPARE -- the text was simply wider than its control. Step the size
       down until it fits, with a floor so it never becomes unreadable. */
    NSFont *fnt=nil; NSSize ts=NSZeroSize; CGFloat avail=r.size.width-2;
    for(;;){
        fnt=[NSFont systemFontOfSize:sz weight:NSFontWeightBold];
        ts=[t sizeWithAttributes:@{NSFontAttributeName:fnt}];
        if(ts.width<=avail || sz<=6.0) break;
        sz-=0.5;
    }
    NSDictionary *at=@{NSFontAttributeName:fnt,
        NSForegroundColorAttributeName:col, NSParagraphStyleAttributeName:ps};
    [t drawInRect:NSMakeRect(r.origin.x, r.origin.y+(r.size.height-ts.height)/2, r.size.width, ts.height) withAttributes:at];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    CFTimeInterval now=CFAbsoluteTimeGetCurrent();
    // background
    NSGradient *bg=[[NSGradient alloc] initWithStartingColor:HEX(27,35,48,1) endingColor:HEX(11,14,20,1)];
    [bg drawInRect:self.bounds angle:-90];

    for (V7Control *c in _controls) {
        NSRect r=[self rectFor:c];
        CGFloat glow = MAX(0,(c.hitUntil-now)/0.18);
        /* Numark red. The hierarchy is kept inside the red family so active vs
           live vs pad-hit still read apart: accent is the brand red, hilite a
           brighter red for live/held state, hot a warm red-orange for pads. */
        NSColor *accent = HEX(206,26,42,1), *hilite=HEX(255,74,86,1), *hot=HEX(255,138,74,1);

        if ([c.kind isEqual:@"platter"]) {
            CGFloat cx=NSMidX(r), cy=NSMidY(r), R=r.size.width/2;
            BOOL spinning = (_platterSpinUntil > now);
            // vinyl disc + concentric grooves (stationary)
            NSBezierPath *disc=[NSBezierPath bezierPathWithOvalInRect:r];
            NSGradient *vg=[[NSGradient alloc] initWithStartingColor:HEX(24,24,28,1) endingColor:HEX(8,8,11,1)];
            [vg drawInBezierPath:disc relativeCenterPosition:NSMakePoint(-0.25,0.25)];
            [HEX(60,66,80,0.5) setStroke];
            for(CGFloat f=0.92;f>0.4;f-=0.09){ NSRect rr=NSInsetRect(r,r.size.width*(1-f)/2,r.size.height*(1-f)/2);
                NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:rr]; ring.lineWidth=1.5;[ring stroke]; }
            // ---- rotating layer: radial spokes + center label spin with the encoder ----
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *tr=[NSAffineTransform transform];
            [tr translateXBy:cx yBy:cy]; [tr rotateByRadians:_platterAngle]; [tr translateXBy:-cx yBy:-cy]; [tr concat];
            NSColor *spoke = spinning ? HEX(255,74,86,0.85) : HEX(90,100,120,0.5);
            for(int i=0;i<8;i++){ double a=i*M_PI/4.0;
                NSBezierPath *sp=[NSBezierPath bezierPath]; sp.lineWidth=(i==0?3.0:1.5);
                [sp moveToPoint:NSMakePoint(cx+cos(a)*R*0.40, cy+sin(a)*R*0.40)];
                [sp lineToPoint:NSMakePoint(cx+cos(a)*R*0.90, cy+sin(a)*R*0.90)];
                if(i==0) [(spinning?HEX(255,190,120,1):HEX(140,110,80,1)) setStroke]; else [spoke setStroke];  // index spoke: warm, to stay visible against red
                [sp stroke]; }
            NSRect lab=NSInsetRect(r,r.size.width*0.34,r.size.height*0.34);
            NSGradient *lg=[[NSGradient alloc] initWithStartingColor:HEX(214,38,50,1) endingColor:HEX(150,14,26,1)];
            [lg drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:lab] angle:-70];
            [self label:@"V7" in:lab color:NSColor.whiteColor size:r.size.height*0.11];
            [NSGraphicsContext restoreGraphicsState];
            // active-spin glow ring
            if(spinning || glow>0){ CGFloat a=spinning?0.85:glow; [[hilite colorWithAlphaComponent:a] setStroke];
                NSBezierPath *g=[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r,-3,-3)]; g.lineWidth=4;[g stroke]; }
            continue;
        }
        if ([c.kind isEqual:@"fader"]) {
            [self drawRoundRect:r radius:6 fill:HEX(20,25,34,1) stroke:HEX(36,44,58,1) width:1];
            /* This view isFlipped, so v is measured DOWN from the top of the slot:
               v=0 is the top, v=1 the bottom. The V7 reports its pitch fader with
               the high value at the "+" end, which is at the BOTTOM of the panel
               (see the "+%" marking under the fader on the real deck), so value
               maps straight to v. Inverting it -- the previous 1.0-v -- made the
               on-screen cap travel the opposite way to the physical fader. */
            CGFloat raw = c.lastVal<0?0.5:(c.lastVal/127.0);
            CGFloat v = c.faderInverted ? (1.0-raw) : raw;
            NSRect cap=NSMakeRect(r.origin.x+2, r.origin.y+2+v*(r.size.height-r.size.height*0.14-4), r.size.width-4, r.size.height*0.14);
            [self drawRoundRect:cap radius:3 fill:(glow>0?hilite:accent) stroke:nil width:0];
            [self label:c.label in:NSMakeRect(r.origin.x-6,NSMaxY(r)+2,r.size.width+12,12) color:HEX(91,100,115,1) size:9];
            continue;
        }
        if ([c.kind isEqual:@"strip"]) {
            [self drawRoundRect:r radius:5 fill:HEX(20,25,34,1) stroke:HEX(36,44,58,1) width:1];
            if(c.lastVal>=0 && glow>0){ CGFloat x=r.origin.x+(c.lastVal/127.0)*(r.size.width-6);
                [[hilite colorWithAlphaComponent:glow] setFill]; NSRectFill(NSMakeRect(x,r.origin.y+2,6,r.size.height-4)); }
            [self label:c.label in:r color:HEX(91,100,115,1) size:9];
            continue;
        }
        /* Three-position BLEEP / centre / REVERSE switch. BLEEP is momentary and
           REVERSE latches, so the lever stays parked at REVERSE until the switch
           is physically moved back -- drawing this as a button would show a
           180 ms flash for a state that can last minutes. */
        if ([c.cid isEqual:@"reverse"]) {
            [self drawRoundRect:r radius:0 fill:HEX(16,20,28,1) stroke:HEX(51,64,90,1) width:1];
            CGFloat th=r.size.height/3.0;
            NSRect lev=NSMakeRect(r.origin.x+2,
                                  r.origin.y + (_revState==1?0:(_revState==2?2*th:th)) + 2,
                                  r.size.width-4, th-4);
            NSColor *lc = _revState==2 ? accent : (_revState==1 ? hilite : HEX(70,80,100,1));
            [self drawRoundRect:lev radius:0 fill:lc stroke:nil width:0];
            [self label:@"BLEEP" in:NSMakeRect(r.origin.x-8,r.origin.y-11,r.size.width+16,10)
                  color:(_revState==1?hilite:HEX(91,100,115,1)) size:8];
            [self label:@"REV" in:NSMakeRect(r.origin.x-8,NSMaxY(r)+1,r.size.width+16,10)
                  color:(_revState==2?accent:HEX(91,100,115,1)) size:8];
            continue;
        }
        /* BEAT DIFF is an OUTPUT-only LED bar (host -> device): it shows the phase
           error between the two decks, white in the centre when synced, red out
           to 25/50/75/100% of a beat. The device never reports it, so it has no
           input address and can never light from incoming MIDI -- drawn as the
           real segmented strip rather than a button so the panel reads correctly. */
        if ([c.cid isEqual:@"beatdiff"]) {
            int n=9; CGFloat gap=2.0;
            CGFloat sw=(r.size.width-gap*(n-1))/n;
            for(int i=0;i<n;i++){
                NSRect seg=NSMakeRect(r.origin.x+i*(sw+gap), r.origin.y, sw, r.size.height);
                NSColor *col = (i==n/2) ? HEX(150,160,180,1)
                             : (abs(i-n/2)==1 ? HEX(70,52,60,1) : HEX(58,38,44,1));
                [self drawRoundRect:seg radius:0 fill:col stroke:nil width:0];
            }
            [self label:c.label in:NSMakeRect(r.origin.x-20,NSMaxY(r)+1,r.size.width+40,11)
                  color:HEX(91,100,115,1) size:8];
            continue;
        }
        /* DECK SELECT is a two-position SWITCH, not a momentary button, and its
           position is reported continuously on B0 7D (00 = A, 01 = B) rather
           than as a press. Drawing it as a button threw away the one piece of
           state that matters most on this deck: which block the hardware is
           actually emitting on. Rendered as an A|B switch showing the live side. */
        if ([c.cid isEqual:@"decksel"]) {
            [self drawRoundRect:r radius:0 fill:HEX(16,20,28,1) stroke:HEX(51,64,90,1) width:1];
            CGFloat hw=r.size.width/2;
            NSRect act=NSMakeRect(r.origin.x+(_activeDeck?hw:0), r.origin.y, hw, r.size.height);
            [self drawRoundRect:NSInsetRect(act,2,2) radius:0
                           fill:(glow>0?hilite:accent) stroke:nil width:0];
            [self label:@"A" in:NSMakeRect(r.origin.x,r.origin.y,hw,r.size.height)
                  color:(_activeDeck?HEX(120,130,150,1):NSColor.whiteColor) size:11];
            [self label:@"B" in:NSMakeRect(r.origin.x+hw,r.origin.y,hw,r.size.height)
                  color:(_activeDeck?NSColor.whiteColor:HEX(120,130,150,1)) size:11];
            [self label:@"DECK" in:NSMakeRect(r.origin.x-10,NSMaxY(r)+1,r.size.width+20,11)
                  color:HEX(91,100,115,1) size:8];
            continue;
        }
        /* Knobs render as actual knobs: a round body, a travel arc, and a pointer
           that rotates. Two value sources -- an absolute knob (START/STOP TIME,
           FX PARAM) sweeps 0..127 over 270 degrees with end stops, whereas a
           relative ENCODER (BROWSE, FX SELECT) has no position at all and simply
           accumulates detents, so it spins continuously and draws no arc.
           NOTE: the view isFlipped, so screen-clockwise from 12 o'clock is
           (sin t, -cos t) -- using the usual (cos, sin) would mirror the sweep. */
        if ([c.kind isEqual:@"knob"] || [c.kind isEqual:@"encoder"]) {
            BOOL enc=[c.kind isEqual:@"encoder"];
            CGFloat cx=NSMidX(r), cy=NSMidY(r), R=MIN(r.size.width,r.size.height)/2-1;
            double t   = (c.lastVal<0 ? 0.5 : c.lastVal/127.0);
            double ang = enc ? c.knobAngle : (-135.0 + t*270.0)*M_PI/180.0;
            /* Travel arc, absolute knobs only. Built from the SAME (sin,-cos)
               parametrisation as the pointer rather than AppKit's arc helper --
               that helper measures angles in the coordinate system, which this
               flipped view mirrors, so it would sweep opposite to the pointer. */
            if(!enc){
                for(int pass=0; pass<2; pass++){          // 0 = full track, 1 = value trail
                    double span = pass ? 270.0*t : 270.0;
                    if(pass && t<=0.001) continue;
                    NSBezierPath *arc=[NSBezierPath bezierPath];
                    arc.lineWidth = pass?3.0:2.0; arc.lineCapStyle=NSLineCapStyleRound;
                    int steps = pass ? MAX(2,(int)(span/7)) : 40;
                    for(int i=0;i<=steps;i++){
                        double a=(-135.0 + span*i/steps)*M_PI/180.0;
                        NSPoint pp=NSMakePoint(cx+sin(a)*(R+3), cy-cos(a)*(R+3));
                        if(i==0) [arc moveToPoint:pp]; else [arc lineToPoint:pp];
                    }
                    [(pass ? (glow>0?hilite:accent) : HEX(36,44,58,1)) setStroke];
                    [arc stroke];
                }
            }
            NSRect body=NSMakeRect(cx-R,cy-R,2*R,2*R);
            NSBezierPath *bp=[NSBezierPath bezierPathWithOvalInRect:body];
            NSGradient *kg=[[NSGradient alloc] initWithStartingColor:HEX(52,61,79,1)
                                                         endingColor:HEX(17,21,29,1)];
            [kg drawInBezierPath:bp angle:-70];
            [(glow>0?hilite:HEX(51,64,90,1)) setStroke]; bp.lineWidth=(glow>0?2:1); [bp stroke];
            if(enc){
                /* A relative encoder has NO limits and no position, so a pointer
                   would be a lie -- there is no "where it is". Draw detent marks
                   around the rim that turn with it instead: motion and direction
                   are the only real information the device gives us. */
                for(int i=0;i<12;i++){
                    double a=ang + i*(2*M_PI/12.0);
                    NSBezierPath *tk=[NSBezierPath bezierPath];
                    tk.lineWidth=2.0; tk.lineCapStyle=NSLineCapStyleRound;
                    [tk moveToPoint:NSMakePoint(cx+sin(a)*R*0.70, cy-cos(a)*R*0.70)];
                    [tk lineToPoint:NSMakePoint(cx+sin(a)*R*0.93, cy-cos(a)*R*0.93)];
                    [(glow>0?hilite:HEX(126,138,160,1)) setStroke]; [tk stroke];
                }
            } else {
                NSBezierPath *pt=[NSBezierPath bezierPath]; pt.lineWidth=2.5; pt.lineCapStyle=NSLineCapStyleRound;
                [pt moveToPoint:NSMakePoint(cx+sin(ang)*R*0.28, cy-cos(ang)*R*0.28)];
                [pt lineToPoint:NSMakePoint(cx+sin(ang)*R*0.82, cy-cos(ang)*R*0.82)];
                [(glow>0?NSColor.whiteColor:HEX(150,160,180,1)) setStroke]; [pt stroke];
            }
            /* Pushable knobs carry a centre dot: dim when idle (so you can see
               the knob CAN be pushed), filled and ringed while held. */
            if(c.pressStatus){
                NSRect dot=NSInsetRect(body,R*0.62,R*0.62);
                NSBezierPath *dp=[NSBezierPath bezierPathWithOvalInRect:dot];
                [(c.pressHeld?hilite:HEX(64,74,94,1)) setFill]; [dp fill];
                if(c.pressHeld){ [NSColor.whiteColor setStroke]; dp.lineWidth=1.5; [dp stroke];
                    NSBezierPath *hl=[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(body,-2,-2)];
                    hl.lineWidth=2; [hilite setStroke]; [hl stroke]; }
            }
            [self label:c.label in:NSMakeRect(r.origin.x-12,NSMaxY(r)+1,r.size.width+24,11)
                  color:HEX(91,100,115,1) size:8];
            continue;
        }
        // buttons / pads -- square corners, matching the real panel's hard edges
        BOOL pad=[c.kind isEqual:@"pad"];
        CGFloat rad = 0;
        NSColor *fill = HEX(20,25,34,1);
        NSColor *stroke = c.hasMap?HEX(51,64,90,1):HEX(36,44,58,1);
        if(c==_armed) stroke=HEX(217,150,58,1);
        if(glow>0) fill = (pad?hot:accent);
        [self drawRoundRect:r radius:rad fill:fill stroke:stroke width:(c==_armed?2:1)];
        [self label:c.label in:r color:(glow>0?NSColor.whiteColor:HEX(139,147,165,1)) size:10];
    }
}

// ---- persistence ----
/* Defaults now ship in the control table above (docs/CONTROL-MAP.md), so the
   panel is live on first launch. Previously only the platter was pre-mapped --
   and to CC 0x00, deck A -- so on a unit switched to deck B (which reports on
   CC 0x02) literally nothing on the panel ever lit up. A saved map still wins,
   so Learn mode can still correct any address. */
- (void)loadMap {
    NSDictionary *m=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"map"];
    for(V7Control *c in _controls){ c.hasMap=c.defHasMap; c.status=c.defStatus; c.d0=c.defD0; }
    for(V7Control *c in _controls){ NSString *v=m[c.cid]; if(v){ NSArray *p=[v componentsSeparatedByString:@","];
        if(p.count==2){ c.hasMap=YES; c.status=(uint8_t)[p[0] intValue]; c.d0=(uint8_t)[p[1] intValue]; } } }
}
- (void)saveMap {
    NSMutableDictionary *m=[NSMutableDictionary dictionary];
    for(V7Control *c in _controls) if(c.hasMap) m[c.cid]=[NSString stringWithFormat:@"%d,%d",c.status,c.d0];
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"map"];
}
/* Forget user overrides and fall back to the shipped map (loadMap re-seeds from
   the defaults), rather than leaving every control unmapped. */
- (void)clearMap {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"map"];
    [self loadMap]; self.needsDisplay=YES;
}
- (NSString*)exportXML {
    NSMutableString *s=[NSMutableString stringWithString:@"<device name=\"Numark V7\" author=\"OpenV7\" type=\"MIDI\" decks=\"1\">\n"];
    for(V7Control *c in _controls) if(c.hasMap){
        if((c.status&0xF0)==0xE0) [s appendFormat:@"  <map value=\"0x%02x\" name=\"%@\" />\n",c.status,c.cid];
        else [s appendFormat:@"  <map value=\"0x%02x 0x%02x\" name=\"%@\" />\n",c.status,c.d0,c.cid];
    }
    [s appendString:@"</device>\n"]; return s;
}
@end

// ============================================================ CalibrationWizard
/* The V7's calibration is a HARDWARE routine stored in the unit's own firmware:
   the USB cable is unplugged for its entire duration, so the app is blind to it
   and can only guide. It used to be a single NSAlert holding all eleven steps
   as one block of text -- the worst possible shape for a procedure you carry
   out with both hands on a deck, glancing at the screen between actions. No
   sense of place, nothing to mark off, and every instruction competing with ten
   others. One instruction per screen instead.

   Numark publishes ONE support article for the NS7 and the V7 together and
   gives no V7-specific wording, so its "LEFT deck" / "RIGHT deck" references
   are reproduced EXACTLY rather than reinterpreted for a single-deck unit. A
   guess there would walk the operator through a procedure for hardware they do
   not have; the first screen says so and points at the unit's LEDs as the
   authority. */

/* Content view that also carries the arrow keys, so the wizard can be driven
   without aiming at a button -- the operator's hands are on the deck. */
@interface CalWizardView : NSView
@property (weak) id target;
@property (assign) SEL prevAction, nextAction;
@end
@implementation CalWizardView
- (BOOL)acceptsFirstResponder { return YES; }
/* Painted here rather than via a backing layer: one flat fill does not need
   layer-backing, and a layer-backed view renders blank through
   cacheDisplayInRect:, which is how this panel gets proofed offscreen. */
- (void)drawRect:(NSRect)r { (void)r; [HEX(16,20,28,1) setFill]; NSRectFill(self.bounds); }
- (void)cancelOperation:(id)sender { (void)sender; [self.window close]; }   /* Esc */
- (void)keyDown:(NSEvent*)e {
    if(e.keyCode==123 && _prevAction){ [NSApp sendAction:_prevAction to:_target from:self]; return; }  /* left  */
    if(e.keyCode==124 && _nextAction){ [NSApp sendAction:_nextAction to:_target from:self]; return; }  /* right */
    [super keyDown:e];
}
@end

@interface CalWizard : NSObject <NSWindowDelegate>
@property (strong) NSWindow *win;
@property (strong) NSArray<NSArray*> *steps;
@property (assign) NSInteger idx;
@property (strong) NSTextField *titleLbl,*counterLbl,*dotsLbl,*bodyLbl,*blockLbl,*footLbl;
@property (strong) NSButton *backBtn,*nextBtn;
@property (strong) NSTimer *poll;
@property (assign) BOOL wasBlocked;
- (void)show;
@end

@implementation CalWizard

/* Verbatim from Numark's NS7/V7 calibration article, one instruction per entry
   as @[title, body]. Do not "fix" the left/right deck references -- see above. */
- (NSArray<NSArray*>*)buildSteps {
    /* @[title, body, cableMustBeOut].

       cableMustBeOut gates the Next button on the USB cable actually being
       unplugged, checked against IOKit rather than trusted. It is NO on the
       first screen -- the instruction to unplug has not been given yet, so
       blocking there would demand an action before asking for it -- and NO on
       the last, where reconnecting IS the instruction. Every screen in between
       is a step of the live firmware routine, which a reconnect interrupts.

       Bodies spanning several source lines are PARENTHESISED: inside an NSArray
       literal, adjacent @"" literals are also how a missing comma looks, and
       -Wobjc-string-concatenation rightly warns on it. The parens say "this
       concatenation is deliberate" and keep the build warning-free.

       Step text is verbatim from Numark's NS7/V7 calibration article. Do not
       "fix" the left/right deck references -- see the note above this class. */
    return @[
      @[@"Before you begin",
        (@"Calibration is stored in the V7's own firmware. OpenV7 cannot run it over USB — "
          "the cable stays unplugged for every step that follows.\n\n"
          "Numark publishes a single article covering both the NS7 and the V7, and it never says "
          "what \u201cLEFT deck\u201d and \u201cRIGHT deck\u201d mean on a single-deck V7. Those references are "
          "left exactly as Numark wrote them.\n\n"
          "The LEDs on the unit are the source of truth. If they disagree with a step here, believe the unit."),
        @NO],
      @[@"Power off",
        @"Unplug the USB cable and make sure the V7 is powered OFF.",
        @YES],
      @[@"Enter calibration mode",
        (@"Hold the RIGHT deck HOT CUE buttons 1 and 3, then turn the power ON.\n\n"
          "They flash twice to confirm calibration mode."),
        @YES],
      @[@"Wait for it to initialise",
        @"Wait 10–20 seconds.",
        @YES],
      @[@"Maximum travel",
        (@"Set every fader and knob to MAXIMUM / far right, and the pitch fader to the BOTTOM.\n\n"
          "Press LEFT deck HOT CUE 1 when it lights."),
        @YES],
      @[@"Minimum travel",
        (@"Set every fader and knob to MINIMUM / far left, and the pitch fader to the TOP.\n\n"
          "Press LEFT deck HOT CUE 1 when it lights."),
        @YES],
      @[@"Left strip search",
        (@"Touch the strip at the far RIGHT, then the far LEFT, then the CENTRE.\n\n"
          "Press HOT CUE 1 at each of the three positions."),
        @YES],
      @[@"Right strip search",
        (@"Repeat the far-right, far-left and centre touches on the right strip.\n\n"
          "Press HOT CUE 1 at each of the three positions."),
        @YES],
      @[@"Centre everything",
        @"Set all controls to the MIDDLE position, then press LEFT deck HOT CUE 1.",
        @YES],
      @[@"Confirmation",
        @"LEFT deck HOT CUE 1–5 flash — calibration is complete.",
        @YES],
      @[@"Finish",
        (@"Power-cycle the unit before reconnecting USB.\n\n"
          "Then reconnect and use the Tester panel to confirm every fader reaches full travel "
          "and the strip search responds end to end."),
        @NO],
    ];
}

- (instancetype)init {
    if((self=[super init])){ _steps=[self buildSteps]; _idx=0; [self build]; }
    return self;
}

- (void)build {
    NSRect f=NSMakeRect(0,0,580,440);
    _win=[[NSWindow alloc] initWithContentRect:f
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    _win.title=@"Numark V7 — Calibration";
    _win.releasedWhenClosed=NO;
    /* Dark, so the system controls match the rest of the app rather than
       rendering a bright panel next to the dark tester. */
    if(@available(macOS 10.14,*)) _win.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [_win center];

    CalWizardView *cv=[[CalWizardView alloc] initWithFrame:f];
    cv.target=self; cv.prevAction=@selector(back:); cv.nextAction=@selector(next:);
    _win.contentView=cv;

    CGFloat m=32, w=f.size.width-2*m;

    _titleLbl=[NSTextField labelWithString:@""];
    _titleLbl.frame=NSMakeRect(m,378,w-130,28);
    _titleLbl.font=[NSFont systemFontOfSize:20 weight:NSFontWeightBold];
    _titleLbl.textColor=NSColor.whiteColor;
    [cv addSubview:_titleLbl];

    _counterLbl=[NSTextField labelWithString:@""];
    _counterLbl.frame=NSMakeRect(m+w-130,383,130,18);
    _counterLbl.alignment=NSTextAlignmentRight;
    _counterLbl.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _counterLbl.textColor=HEX(139,147,165,1);
    [cv addSubview:_counterLbl];

    _dotsLbl=[NSTextField labelWithString:@""];
    _dotsLbl.frame=NSMakeRect(m,356,w,18);
    [cv addSubview:_dotsLbl];

    /* Generous height: the longest body is the "Before you begin" caveat, and a
       clipped instruction is worse than none. Nothing scrolls. */
    _bodyLbl=[NSTextField wrappingLabelWithString:@""];
    _bodyLbl.frame=NSMakeRect(m,164,w,186);
    _bodyLbl.font=[NSFont systemFontOfSize:14];
    _bodyLbl.textColor=HEX(210,218,230,1);
    [cv addSubview:_bodyLbl];

    /* Persistent, because it is true on EVERY screen. A warning that scrolls
       away with step 1 is a warning you plugged the cable back in without. */
    /* Shown only while the cable is in on a step that forbids it. Sits directly
       under the instruction, where the eye already is, rather than beside the
       button that quietly stopped working. */
    _blockLbl=[NSTextField wrappingLabelWithString:@""];
    _blockLbl.frame=NSMakeRect(m,116,w,40);
    _blockLbl.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _blockLbl.textColor=HEX(255,74,86,1);
    [cv addSubview:_blockLbl];

    /* Repeated on every screen it applies to, rather than stated once on step 1
       and forgotten -- a cable warning that scrolled away ten screens ago is a
       warning you plugged the cable back in without. Hidden on exactly the
       screens where it is NOT true: the intro, and the finish step whose whole
       instruction is to reconnect. A standing warning that contradicts the
       instruction directly above it teaches the operator to ignore it. */
    _footLbl=[NSTextField wrappingLabelWithString:
        @"⚠  The USB cable stays UNPLUGGED for this step. This lives in the V7's firmware — OpenV7 cannot run it for you."];
    _footLbl.frame=NSMakeRect(m,68,w,42);
    _footLbl.font=[NSFont systemFontOfSize:11];
    _footLbl.textColor=HEX(217,150,58,1);
    [cv addSubview:_footLbl];

    _backBtn=[NSButton buttonWithTitle:@"Back" target:self action:@selector(back:)];
    _backBtn.frame=NSMakeRect(m,22,100,32); _backBtn.bezelStyle=NSBezelStyleRounded;
    [cv addSubview:_backBtn];

    _nextBtn=[NSButton buttonWithTitle:@"Next" target:self action:@selector(next:)];
    _nextBtn.frame=NSMakeRect(m+w-120,22,120,32); _nextBtn.bezelStyle=NSBezelStyleRounded;
    _nextBtn.keyEquivalent=@"\r";                       /* Return advances */
    [cv addSubview:_nextBtn];

    _win.delegate=self;
    [self render];
}

/* The cable is in, on a step that requires it out. */
- (BOOL)blocked { return [_steps[_idx][2] boolValue] && v7IsPluggedIn(); }

/* Poll rather than subscribe to IOKit matching notifications: this window is
   open for the length of a manual hardware procedure, twice a second costs
   nothing, and a notification setup would be far more machinery for a gate that
   only has to feel instant to someone reaching behind a deck. Re-renders only
   on a CHANGE, so the panel is not rebuilt 120 times a minute. */
- (void)pollTick {
    BOOL b=[self blocked];
    if(b!=_wasBlocked){ _wasBlocked=b; [self render]; }
}
- (void)windowWillClose:(NSNotification*)n { (void)n; [_poll invalidate]; _poll=nil; }

- (void)render {
    NSArray *st=_steps[_idx];
    _titleLbl.stringValue=st[0];
    _bodyLbl.stringValue=st[1];
    _counterLbl.stringValue=[NSString stringWithFormat:@"Step %ld of %ld",(long)(_idx+1),(long)_steps.count];

    /* Filled dots for everything up to and including the current step, so the
       row reads as progress rather than as a position marker. */
    NSMutableAttributedString *as=[NSMutableAttributedString new];
    NSFont *df=[NSFont systemFontOfSize:12];
    for(NSInteger i=0;i<(NSInteger)_steps.count;i++){
        BOOL done=(i<=_idx);
        [as appendAttributedString:[[NSAttributedString alloc]
            initWithString:(done?@"● ":@"○ ")
                attributes:@{NSFontAttributeName:df,
                             NSForegroundColorAttributeName:(done?HEX(206,26,42,1):HEX(60,70,88,1))}]];
    }
    _dotsLbl.attributedStringValue=as;

    _backBtn.enabled=(_idx>0);
    _nextBtn.title=(_idx+1==(NSInteger)_steps.count)?@"Done":@"Next";

    /* Refuse to advance while the V7 is still on the bus. The routine runs in
       the unit's firmware with the host detached, so carrying on with the cable
       in walks the operator through steps the hardware is not actually
       performing -- and the first sign of that is a deck behaving oddly hours
       later. Back stays live so they can still move around. */
    _footLbl.hidden=![_steps[_idx][2] boolValue];
    BOOL blocked=[self blocked];
    _wasBlocked=blocked;
    _nextBtn.enabled=!blocked;
    _blockLbl.stringValue = blocked
        ? @"⛔  The V7 is still connected. Unplug the USB cable to continue."
        : @"";
}

- (void)back:(id)s { (void)s; if(_idx>0){ _idx--; [self render]; } }
- (void)next:(id)s { (void)s;
    if([self blocked]){ NSBeep(); [self render]; return; }   /* also covers Return and → */
    if(_idx+1<(NSInteger)_steps.count){ _idx++; [self render]; } else [_win close];
}

/* Always reopens at step 1. Resuming mid-procedure would be a trap: if the
   window was closed because the operator restarted the hardware routine,
   dropping them back at step 7 resumes a procedure that is no longer running. */
- (void)show {
    _idx=0; [self render];
    if(!_poll) _poll=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                        selector:@selector(pollTick) userInfo:nil repeats:YES];
    [_win makeKeyAndOrderFront:nil];
    [_win makeFirstResponder:_win.contentView];
    [NSApp activateIgnoringOtherApps:YES];
}
@end

// ============================================================ AppDelegate
@interface AppDelegate : NSObject <NSApplicationDelegate, DeviceViewDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSTask *task;
@property (strong) NSTimer *timer;
@property (strong) NSMenuItem *statusLine, *loginItem;
@property (strong) NSWindow *tester;
@property (strong) DeviceView *dev;
@property (strong) NSTextView *log;
@property (strong) NSButton *learnBtn;
// CoreMIDI
@property (assign) MIDIClientRef client;
@property (assign) MIDIPortRef inPort;
@property (assign) MIDIPortRef outPort;    // to send to device
@property (assign) MIDIEndpointRef dest;   // send target
@property (assign) MIDIEndpointRef boundSrc;   // the source inPort is currently connected to
@property (assign) BOOL connected;
@property (assign) long lastRx;                // for "how long since the last message"
@property (assign) NSTimeInterval lastRxAt;
@property (strong) NSTimer *timer2;
@property (strong) NSTextField *midiStat;
@property (strong) id activityToken;
@property (strong) CalWizard *calWiz;
/* Set for the duration of stopBridge's teardown wait. That wait now pumps the
   run loop (so the UI stays alive), which means the 3 s tick timer and a second
   click on "Restart bridge" can both re-enter -- and relaunching the bridge
   while the old one still holds the USB interfaces is the LIBUSB_ERROR_BUSY
   race the wait exists to prevent. The guard makes pumping safe. */
@property (assign) BOOL stopping;
- (void)flushRx;
@end

static AppDelegate *gApp;

/* Decouple UI from MIDI rate: the CoreMIDI thread only appends to a ring and
   bumps a counter; a 30fps timer on the main thread drains it. Prevents the
   high-rate platter stream from flooding/freezing the main run loop. */
#import <pthread.h>
#define RXQ 8192
static struct rxm { uint8_t s, d0, d1; } g_rxq[RXQ];
static volatile long g_rxw = 0, g_rxr = 0, g_rxcount = 0;
static pthread_mutex_t g_rxmtx = PTHREAD_MUTEX_INITIALIZER;

static MIDIEndpointRef findEndpointNamed(NSString *name, BOOL source) {
    ItemCount n = source?MIDIGetNumberOfSources():MIDIGetNumberOfDestinations();
    for (ItemCount i=0;i<n;i++){
        MIDIEndpointRef e = source?MIDIGetSource(i):MIDIGetDestination(i);
        CFStringRef nm=NULL; MIDIObjectGetStringProperty(e,kMIDIPropertyDisplayName,&nm);
        BOOL match = nm && [name isEqualToString:(__bridge NSString*)nm];
        if(nm) CFRelease(nm);
        if(match) return e;
    }
    return 0;
}

static void MIDIReadCB(const MIDIPacketList *pl, void *a, void *b) {
    (void)a;(void)b;
    const MIDIPacket *p=&pl->packet[0];
    pthread_mutex_lock(&g_rxmtx);
    for(unsigned i=0;i<pl->numPackets;i++){
        for(unsigned j=0;j<p->length;){
            uint8_t s=p->data[j];
            if(s<0x80 || s>=0xF8){ j++; continue; }
            uint8_t d0=(j+1<p->length)?p->data[j+1]:0;
            uint8_t d1=(j+2<p->length)?p->data[j+2]:0;
            int len=((s&0xF0)==0xC0||(s&0xF0)==0xD0)?2:3;
            g_rxq[g_rxw % RXQ]=(struct rxm){s,d0,d1}; g_rxw++; g_rxcount++;
            j+=len;
        }
        p=MIDIPacketNext(p);
    }
    pthread_mutex_unlock(&g_rxmtx);
}

@implementation AppDelegate

- (NSString*)bridgePath { return [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"openv7-bridge"]; }
- (BOOL)bridgeRunning { return _task && _task.isRunning; }

- (void)startBridge {
    if(_stopping || [self bridgeRunning]) return;   /* never relaunch into a teardown */
    NSString *path=[self bridgePath]; if(!path) return;
    NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:path];
    /* --supervised: if this app is force-quit or crashes, applicationWillTerminate
       never runs and the bridge is orphaned while still holding both USB
       interfaces -- after which every relaunch is refused with
       LIBUSB_ERROR_ACCESS. The flag makes the child exit on reparenting. */
    t.arguments = @[@"--supervised"];
    t.qualityOfService = NSQualityOfServiceUserInteractive;   /* keep the child un-throttled */
    t.standardOutput=[NSFileHandle fileHandleWithNullDevice];
    /* Keep the bridge's status lines (handshake, teardown) in a support log --
       APPENDED, not truncated.

       The bridge is relaunched automatically whenever it exits, and recreating
       the file on each launch destroyed the record of WHY the previous one
       exited. That is precisely the evidence an intermittent startup fault
       needs, and losing it is why a bridge that had lost its USB handle went
       undiagnosed: every relaunch wiped the disconnect message that explained
       it. Each launch is stamped so a failure can be tied to its run.

       One generation is rolled at 1 MB, so an unattended run cannot fill /tmp
       (a spin-forever bug once wrote 2.7 MB in a day). */
    NSString *lp=@"/tmp/openv7_bridge.log";
    NSFileManager *fm=[NSFileManager defaultManager];
    NSDictionary *la=[fm attributesOfItemAtPath:lp error:NULL];
    if(la && [la fileSize] > 1024*1024){
        [fm removeItemAtPath:[lp stringByAppendingString:@".1"] error:NULL];
        [fm moveItemAtPath:lp toPath:[lp stringByAppendingString:@".1"] error:NULL];
    }
    if(![fm fileExistsAtPath:lp]) [fm createFileAtPath:lp contents:nil attributes:nil];
    NSFileHandle *elog=[NSFileHandle fileHandleForWritingAtPath:lp];
    [elog seekToEndOfFile];
    [elog writeData:[[NSString stringWithFormat:@"\n===== bridge launch %@ =====\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle]]
        dataUsingEncoding:NSUTF8StringEncoding]];
    t.standardError = elog ?: [NSFileHandle fileHandleWithNullDevice];
    NSError *e=nil; if([t launchAndReturnError:&e]) _task=t;
    _connected=NO;   // reconnect the tester to the freshly-published source
    [self refresh];
}
/* SIGTERM (not kill) so the bridge runs its graceful USB teardown, leaving the
   device clean for the next launch -- then WAIT for it to actually exit.

   [NSTask terminate] only DELIVERS the signal; it returns immediately while the
   child is still inside a teardown that takes ~600 ms (cancel every transfer,
   pump the event loop 12 x 50 ms, drop to the zero-bandwidth alt setting,
   release both interfaces). Clearing _task straight afterwards made
   bridgeRunning report NO while the old process was still very much alive, so
   restart: launched the replacement into that window -- where it contended with
   the dying process for the same USB interfaces and lost with
   LIBUSB_ERROR_BUSY, which the bridge then swallowed and reported as a clean
   bring-up. Waiting closes the window at the source.

   Bounded and force-killed on timeout: a wedged child must never hang the UI. */
- (void)stopBridge { [self stopBridgePumpingRunLoop:YES]; }

/* pump=YES keeps the main run loop turning during the wait, so the menu and the
   tester stay responsive instead of freezing for the ~600 ms teardown (a
   sleep-only loop guarantees a visible hang on every "Restart bridge" and
   "Quit"). Re-entry during the pump is blocked by _stopping.

   pump=NO for applicationWillTerminate:, where AppKit is already tearing the
   app down and running more main-thread work is not worth the risk -- there is
   no UI left to keep responsive there anyway. */
- (void)stopBridgePumpingRunLoop:(BOOL)pump {
    if(![self bridgeRunning]){ _task=nil; return; }
    NSTask *t=_task; _task=nil;
    _stopping=YES;
    [t terminate];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2.0];
    while(t.isRunning && [deadline timeIntervalSinceNow]>0){
        if(pump) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        else     [NSThread sleepForTimeInterval:0.02];
    }
    /* BOUNDED, unlike the waitUntilExit this replaces. SIGKILL cannot be caught,
       but it is not delivered until the target leaves any uninterruptible kernel
       wait -- and this child sits in USB ioctls constantly, so "stuck in the
       kernel" is a normal state for it, not an exotic one. An unbounded wait
       here hangs the whole app with no way out; giving up after a second leaves
       at worst one process that launchd reaps when we exit. */
    if(t.isRunning){
        kill(t.processIdentifier, SIGKILL);
        NSDate *hard=[NSDate dateWithTimeIntervalSinceNow:1.0];
        while(t.isRunning && [hard timeIntervalSinceNow]>0) [NSThread sleepForTimeInterval:0.02];
    }
    _stopping=NO;
}

/* Bind to the bridge's CoreMIDI source, re-binding whenever it is republished.

   Keyed on the ENDPOINT REF, not on a _connected flag. Every bridge restart
   disposes the old endpoint and creates a new one that happens to carry the
   same name, so "already connected" is only true while the ref is unchanged --
   the previous flag-only test could leave the port attached to a disposed
   endpoint and consider the job done. Disconnecting the old ref first also
   stops connections stacking up over a long session of restarts. */
- (void)connectMIDI {
    if(!_client) MIDIClientCreate(CFSTR("OpenV7 Tester"), NULL, NULL, &_client);
    if(!_inPort) MIDIInputPortCreate(_client, CFSTR("in"), MIDIReadCB, NULL, &_inPort);
    if(!_outPort) MIDIOutputPortCreate(_client, CFSTR("out"), &_outPort);
    MIDIEndpointRef src=findEndpointNamed(@"Numark V7", YES);
    _dest = findEndpointNamed(@"Numark V7", NO);
    if(src != _boundSrc){
        if(_boundSrc) MIDIPortDisconnectSource(_inPort, _boundSrc);
        if(src) MIDIPortConnectSource(_inPort, src, NULL);
        _boundSrc = src;
    }
    _connected = (src!=0);
    [self updateMidiStat];
}
- (void)sendBytes:(const uint8_t*)b len:(int)n {
    if(!_dest) _dest=findEndpointNamed(@"Numark V7", NO);
    if(!_dest || !_outPort) return;
    Byte buf[64]; MIDIPacketList *pl=(MIDIPacketList*)buf; MIDIPacket *p=MIDIPacketListInit(pl);
    p=MIDIPacketListAdd(pl,sizeof buf,p,0,n,b);
    MIDISend(_outPort, _dest, pl);
}
/* Report whether MIDI is actually MOVING, not just whether an endpoint exists.

   "An endpoint named Numark V7 is registered" is a proxy, and a stale one: a
   bridge holding a dead USB handle keeps its endpoint published, which is how
   this line read "connected" for 11 hours while nothing arrived. The age of the
   last message is the only real signal the tester has, so show it.

   It is deliberately NOT rendered as a fault: the V7 is genuinely silent when
   idle (docs/HANDOFF-MAC.md), so a long gap means "untouched" just as often as
   "broken". Stating the age lets the operator tell the difference by spinning
   the platter; claiming an error here would cry wolf on every idle deck. */
- (void)updateMidiStat {
    if(!_midiStat) return;
    if(!_connected){
        _midiStat.stringValue=@"MIDI: waiting for bridge…";
        _midiStat.textColor=HEX(217,150,58,1);
        return;
    }
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate];
    if(g_rxcount!=_lastRx){ _lastRx=g_rxcount; _lastRxAt=now; }
    NSString *age = _lastRxAt ? [NSString stringWithFormat:@"last %.0fs ago", now-_lastRxAt]
                              : @"nothing yet";
    _midiStat.stringValue=[NSString stringWithFormat:@"MIDI: connected · %ld msgs · %@",
        g_rxcount, age];
    _midiStat.textColor = HEX(59,189,138,1);
}

- (void)flushRx {
    [self updateMidiStat];
    if(!_dev) return;
    pthread_mutex_lock(&g_rxmtx);
    if(g_rxw - g_rxr > RXQ) g_rxr = g_rxw - RXQ;          /* dropped overflow */
    NSMutableString *batch=[NSMutableString string]; int shown=0; BOOL learned=NO;
    while(g_rxr < g_rxw){
        struct rxm m=g_rxq[g_rxr % RXQ]; g_rxr++;
        if([_dev bindArmedToStatus:m.s d0:m.d0]) learned=YES;
        [_dev flashStatus:m.s d0:m.d0 d1:m.d1];
        BOOL hb=(m.s==0xB0 && (m.d0==0x7d||m.d0==0x6e));
        if(!hb && shown<24){
            const char *t=((m.s&0xF0)==0xB0)?"CC":((m.s&0xF0)==0x90)?"On":((m.s&0xF0)==0x80)?"Off":((m.s&0xF0)==0xE0)?"Pitch":"?";
            [batch appendFormat:@"%02x %02x %02x  %s\n",m.s,m.d0,m.d1,t]; shown++;
        }
    }
    pthread_mutex_unlock(&g_rxmtx);
    if(learned) [self updateLearnTitle];
    if(batch.length && _log){
        NSAttributedString *as=[[NSAttributedString alloc] initWithString:batch attributes:@{
            NSFontAttributeName:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName:HEX(180,190,205,1)}];
        [_log.textStorage appendAttributedString:as];
        if(_log.textStorage.length>12000) [_log.textStorage deleteCharactersInRange:NSMakeRange(0,4000)];
        [_log scrollRangeToVisible:NSMakeRange(_log.textStorage.length,0)];
    }
}

// ---- tester window ----
- (void)openTester:(id)sender {
    (void)sender;
    if(_tester){ [_tester makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; return; }
    /* Panel is 800 px tall so the 47 controls have room to breathe; width follows
       the real V7 face aspect (500/553) so nothing is stretched: 800*500/553 = 724. */
    NSRect frame=NSMakeRect(0,0,1084,832);
    _tester=[[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _tester.title=@"OpenV7 — Tester"; _tester.releasedWhenClosed=NO; [_tester center];
    _tester.minSize=NSMakeSize(980,700);
    NSView *cv=_tester.contentView;

    _dev=[[DeviceView alloc] initWithFrame:NSMakeRect(16,16,724,800)];
    _dev.autoresizingMask=NSViewHeightSizable|NSViewMaxXMargin; _dev.delegate=self;
    _dev.wantsLayer=YES; _dev.layer.cornerRadius=16; _dev.layer.masksToBounds=YES;
    [cv addSubview:_dev];

    /* Right-hand pane, stacked from the top of the 832 px content view (this view
       is NOT flipped, so y grows upward). Laid out as explicit rows because the
       previous absolute values had drifted into overlaps when the window grew. */
    CGFloat px=756, pw=312, bw=(pw-6)/2;
    _learnBtn=[NSButton buttonWithTitle:@"Learn mode: off" target:self action:@selector(toggleLearn:)];
    _learnBtn.frame=NSMakeRect(px,790,bw,30); _learnBtn.bezelStyle=NSBezelStyleRounded; [cv addSubview:_learnBtn];
    NSButton *exp=[NSButton buttonWithTitle:@"Export map" target:self action:@selector(exportMap:)];
    exp.frame=NSMakeRect(px+bw+6,790,bw,30); exp.bezelStyle=NSBezelStyleRounded; [cv addSubview:exp];

    /* Restart bridge: tears the USB session down gracefully (SIGTERM, so the
       device is left clean) and brings it straight back. startBridge also clears
       _connected, so the tester re-binds to the freshly published CoreMIDI
       source rather than holding a stale endpoint. */
    NSButton *rst=[NSButton buttonWithTitle:@"Restart bridge" target:self action:@selector(restart:)];
    rst.frame=NSMakeRect(px,754,bw,28); rst.bezelStyle=NSBezelStyleRounded; [cv addSubview:rst];
    NSButton *cal=[NSButton buttonWithTitle:@"Calibration…" target:self action:@selector(openCalibration:)];
    cal.frame=NSMakeRect(px+bw+6,754,bw,28); cal.bezelStyle=NSBezelStyleRounded; [cv addSubview:cal];

    NSTextField *tl=[NSTextField labelWithString:@"Output test:"]; tl.frame=NSMakeRect(px,732,pw,16);
    tl.font=[NSFont systemFontOfSize:10]; tl.textColor=HEX(139,147,165,1); [cv addSubview:tl];
    NSArray *tests=@[@[@"Motor ▶",@"start"],@[@"Brake ■",@"brake"],@[@"45",@"r45"],@[@"33",@"r33"]];
    CGFloat tx=px;
    for(NSArray *t in tests){ NSButton *b=[NSButton buttonWithTitle:t[0] target:self action:@selector(testOut:)];
        b.identifier=t[1]; b.frame=NSMakeRect(tx,700,72,28); b.bezelStyle=NSBezelStyleRounded;
        [cv addSubview:b]; tx+=76; }

    _midiStat=[NSTextField labelWithString:@"MIDI: waiting for bridge…"];
    _midiStat.frame=NSMakeRect(px,674,pw,18); _midiStat.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    [cv addSubview:_midiStat]; [self updateMidiStat];

    NSScrollView *sv=[[NSScrollView alloc] initWithFrame:NSMakeRect(px,16,pw,650)];
    sv.hasVerticalScroller=YES; sv.borderType=NSLineBorder; sv.autoresizingMask=NSViewHeightSizable|NSViewMinXMargin;
    _log=[[NSTextView alloc] initWithFrame:sv.bounds]; _log.editable=NO; _log.drawsBackground=YES;
    _log.backgroundColor=HEX(10,13,19,1); _log.textContainerInset=NSMakeSize(6,6);
    sv.documentView=_log; [cv addSubview:sv];

    [_tester makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if(!_timer2) _timer2=[NSTimer scheduledTimerWithTimeInterval:1.0/30 target:self selector:@selector(anim) userInfo:nil repeats:YES];
}
- (void)anim { if(_tester.isVisible){ [self flushRx]; _dev.needsDisplay=YES; } }

- (void)deviceViewDidArm:(V7Control*)c { [self updateLearnTitle]; }
- (void)updateLearnTitle {
    _learnBtn.title = !_dev.learn ? @"Learn mode: off"
        : (_dev.armed ? [NSString stringWithFormat:@"Learn: press %@…",_dev.armed.label.length?_dev.armed.label:_dev.armed.cid]
                      : @"Learn: click a control");
}
- (void)toggleLearn:(id)s { (void)s; _dev.learn=!_dev.learn; if(!_dev.learn) _dev.armed=nil; [self updateLearnTitle]; _dev.needsDisplay=YES; }
- (void)exportMap:(id)s { (void)s;
    NSString *xml=[_dev exportXML];
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:xml forType:NSPasteboardTypeString];
    NSAlert *a=[NSAlert new]; a.messageText=@"Mapping copied to clipboard";
    a.informativeText=@"A VirtualDJ <device> snippet of your learned controls is on the clipboard. Paste it into mappers/virtualdj/Numark_V7.xml (and docs/PROTOCOL.md).";
    [a addButtonWithTitle:@"OK"]; [a runModal];
}
- (void)testOut:(NSButton*)b {
    const uint8_t start[3]={0xB0,0x43,0x00}, brake[3]={0xB0,0x44,0x00}, r45[3]={0xB0,0x45,0x01}, r33[3]={0xB0,0x45,0x00};
    NSString *k=b.identifier;
    if([k isEqual:@"start"]){ uint8_t rpm[3]={0xB0,0x45,0x00}; [self sendBytes:rpm len:3]; [self sendBytes:start len:3]; }
    else if([k isEqual:@"brake"]) [self sendBytes:brake len:3];
    else if([k isEqual:@"r45"]) [self sendBytes:r45 len:3];
    else if([k isEqual:@"r33"]) [self sendBytes:r33 len:3];
}
- (void)openCalibration:(id)s {
    (void)s;
    if(!_calWiz) _calWiz=[CalWizard new];
    [_calWiz show];
}

/* Diagnostic trace of the CoreMIDI receive path, appended to /tmp/openv7_gui.log
   alongside the bridge's own /tmp/openv7_bridge.log. The bridge can be verified
   from a terminal, but the GUI's half of the link (did the port actually bind?
   is MIDIReadCB firing?) is otherwise invisible, and "nothing is showing up" is
   the one bug report this app is most likely to get. Cheap: one line per 3 s. */
- (void)logDiag {
    NSMutableString *names=[NSMutableString string];
    ItemCount ns=MIDIGetNumberOfSources();
    for(ItemCount i=0;i<ns;i++){
        CFStringRef dn=NULL;
        MIDIObjectGetStringProperty(MIDIGetSource(i),kMIDIPropertyDisplayName,&dn);
        if(dn){ [names appendFormat:@"%@%@",names.length?@",":@"",(__bridge NSString*)dn]; CFRelease(dn); }
    }
    NSString *line=[NSString stringWithFormat:
        @"bridge=%d connected=%d rxCount=%ld testerVisible=%d inPort=%u src=%lu [%@]\n",
        [self bridgeRunning]?1:0, _connected?1:0, g_rxcount,
        _tester.isVisible?1:0, (unsigned)_inPort, (unsigned long)ns, names];
    /* Rolled at 1 MB like the bridge log: this appends a line every 3 s forever
       (~28,800 lines/day), so unbounded it is a slow /tmp leak. */
    NSFileManager *gfm=[NSFileManager defaultManager];
    NSDictionary *ga=[gfm attributesOfItemAtPath:@"/tmp/openv7_gui.log" error:NULL];
    if(ga && [ga fileSize] > 1024*1024){
        [gfm removeItemAtPath:@"/tmp/openv7_gui.log.1" error:NULL];
        [gfm moveItemAtPath:@"/tmp/openv7_gui.log" toPath:@"/tmp/openv7_gui.log.1" error:NULL];
    }
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:@"/tmp/openv7_gui.log"];
    if(!fh){ [gfm createFileAtPath:@"/tmp/openv7_gui.log" contents:nil attributes:nil];
             fh=[NSFileHandle fileHandleForWritingAtPath:@"/tmp/openv7_gui.log"]; }
    if(fh){ [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

// ---- menu bar ----
- (void)tick {
    if(![self bridgeRunning]) [self startBridge];   // relaunch if it exited
    if(!_connected) [self connectMIDI];
    [self refresh];
    [self logDiag];
}
- (void)refresh {
    BOOL up=[self bridgeRunning];
    _item.button.title = up ? @"◉ V7" : @"○ V7";
    _statusLine.title = up ? @"Numark V7 — connected" : @"Numark V7 — not found (plug it in)";
    if(@available(macOS 13.0,*))
        _loginItem.state=(SMAppService.mainAppService.status==SMAppServiceStatusEnabled)?NSControlStateValueOn:NSControlStateValueOff;
    [self updateMidiStat];
}
- (void)toggleLogin:(id)s { (void)s;
    if(@available(macOS 13.0,*)){ NSError *e=nil; SMAppService *svc=SMAppService.mainAppService;
        if(svc.status==SMAppServiceStatusEnabled)[svc unregisterAndReturnError:&e]; else [svc registerAndReturnError:&e]; }
    [self refresh];
}
- (void)restart:(id)s { (void)s; [self stopBridge]; [self startBridge]; }
- (void)quit:(id)s { (void)s; [self stopBridge]; [NSApp terminate:nil]; }

- (void)applicationDidFinishLaunching:(NSNotification*)n {
    (void)n; gApp=self;
    /* keep the app (and its bridge child) out of App Nap so the USB stream isn't throttled */
    self.activityToken = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiated|NSActivityLatencyCritical
        reason:@"Streaming from the Numark V7"];
    _item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _item.button.title=@"○ V7";
    NSMenu *m=[NSMenu new];
    _statusLine=[[NSMenuItem alloc] initWithTitle:@"Numark V7 — starting…" action:nil keyEquivalent:@""];
    _statusLine.enabled=NO; [m addItem:_statusLine];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Open Tester…" action:@selector(openTester:) keyEquivalent:@"t"];
    [m addItemWithTitle:@"Calibration…" action:@selector(openCalibration:) keyEquivalent:@""];
    [m addItemWithTitle:@"Restart bridge" action:@selector(restart:) keyEquivalent:@"r"];
    _loginItem=[[NSMenuItem alloc] initWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    [m addItem:_loginItem];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit OpenV7" action:@selector(quit:) keyEquivalent:@"q"];
    for(NSMenuItem *mi in m.itemArray) if(mi.action) mi.target=self;
    _item.menu=m;

    [self startBridge];
    _timer=[NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self refresh];
}
- (void)applicationWillTerminate:(NSNotification*)n { (void)n; [self stopBridgePumpingRunLoop:NO]; }
@end

int main(void){
    @autoreleasepool {
        NSApplication *app=[NSApplication sharedApplication];
        AppDelegate *d=[AppDelegate new]; app.delegate=d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
