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

static NSColor *HEX(int r,int g,int b,double a){ return [NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a]; }

// ============================================================ V7Control
@interface V7Control : NSObject
@property (copy) NSString *cid, *label, *kind;
@property NSRect frac;                 // x,y,w,h in 0..1 (top-left origin)
@property CFTimeInterval hitUntil;     // glow deadline
@property int lastVal;                 // for faders/strip position
@property BOOL hasMap; @property uint8_t status, d0;
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
@end

@implementation DeviceView
- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _controls = [NSMutableArray array];
        // id, label, x,y,w,h, kind
        NSArray *L = @[
          @[@"browse",@"BROWSE",@.78,@.05,@.16,@.09,@"knob"],
          @[@"load",@"LOAD",@.78,@.16,@.16,@.06,@""],
          @[@"platter",@"",@.22,@.08,@.52,@.46,@"platter"],
          @[@"strip",@"STRIP SEARCH",@.22,@.56,@.52,@.05,@"strip"],
          @[@"pitch",@"PITCH",@.885,@.26,@.075,@.34,@"fader"],
          @[@"keylock",@"KEYLK",@.78,@.26,@.09,@.06,@""],
          @[@"range",@"RANGE",@.78,@.34,@.09,@.06,@""],
          @[@"reverse",@"BLEEP",@.05,@.26,@.13,@.08,@""],
          @[@"slip",@"SLIP",@.05,@.36,@.13,@.06,@""],
          @[@"sync",@"SYNC",@.05,@.44,@.13,@.06,@""],
          @[@"deck",@"DECK",@.05,@.52,@.13,@.06,@""],
          @[@"cue",@"CUE",@.24,@.64,@.15,@.09,@"big"],
          @[@"play",@"PLAY",@.41,@.64,@.15,@.09,@"big"],
          @[@"loopin",@"LOOP IN",@.60,@.64,@.12,@.06,@""],
          @[@"loopout",@"LOOP OUT",@.60,@.71,@.12,@.06,@""],
          @[@"autoloop",@"AUTO",@.74,@.64,@.12,@.13,@"knob"],
          @[@"pad1",@"1",@.05,@.80,@.10,@.09,@"pad"],
          @[@"pad2",@"2",@.17,@.80,@.10,@.09,@"pad"],
          @[@"pad3",@"3",@.29,@.80,@.10,@.09,@"pad"],
          @[@"pad4",@"4",@.41,@.80,@.10,@.09,@"pad"],
          @[@"pad5",@"5",@.53,@.80,@.10,@.09,@"pad"],
          @[@"delete",@"DELETE",@.65,@.80,@.12,@.09,@""],
          @[@"fxon",@"FX ON",@.79,@.80,@.15,@.09,@""],
        ];
        for (NSArray *a in L) {
            V7Control *c = [V7Control new];
            c.cid=a[0]; c.label=a[1];
            c.frac=NSMakeRect([a[2] doubleValue],[a[3] doubleValue],[a[4] doubleValue],[a[5] doubleValue]);
            c.kind=a[6]; c.lastVal=-1;
            [_controls addObject:c];
        }
        [self loadMap];
    }
    return self;
}

- (NSRect)rectFor:(V7Control*)c {
    NSRect b=self.bounds;
    return NSMakeRect(c.frac.origin.x*b.size.width, c.frac.origin.y*b.size.height,
                      c.frac.size.width*b.size.width, c.frac.size.height*b.size.height);
}

- (V7Control*)controlForStatus:(uint8_t)s d0:(uint8_t)d0 {
    for (V7Control *c in _controls) if (c.hasMap && c.status==s &&
        (((s&0xF0)==0xE0) || c.d0==d0)) return c;
    return nil;
}

- (void)flashStatus:(uint8_t)s d0:(uint8_t)d0 d1:(uint8_t)d1 {
    V7Control *c=[self controlForStatus:s d0:d0]; if(!c) return;
    c.hitUntil = CFAbsoluteTimeGetCurrent()+0.18;
    if ([c.kind isEqual:@"fader"]||[c.kind isEqual:@"strip"]) c.lastVal=d1;
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
    NSDictionary *at=@{NSFontAttributeName:[NSFont systemFontOfSize:sz weight:NSFontWeightBold],
        NSForegroundColorAttributeName:col, NSParagraphStyleAttributeName:ps};
    NSSize ts=[t sizeWithAttributes:at];
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
        NSColor *accent = HEX(47,139,255,1), *cyan=HEX(76,201,255,1), *hot=HEX(255,92,122,1);

        if ([c.kind isEqual:@"platter"]) {
            NSBezierPath *disc=[NSBezierPath bezierPathWithOvalInRect:r];
            NSGradient *vg=[[NSGradient alloc] initWithStartingColor:HEX(24,24,28,1) endingColor:HEX(8,8,11,1)];
            [vg drawInBezierPath:disc relativeCenterPosition:NSMakePoint(-0.25,0.25)];
            [HEX(60,66,80,0.5) setStroke];
            for(CGFloat f=0.92;f>0.4;f-=0.09){ NSRect rr=NSInsetRect(r,r.size.width*(1-f)/2,r.size.height*(1-f)/2);
                NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:rr]; ring.lineWidth=1.5;[ring stroke]; }
            NSRect lab=NSInsetRect(r,r.size.width*0.34,r.size.height*0.34);
            NSGradient *lg=[[NSGradient alloc] initWithStartingColor:HEX(47,139,255,1) endingColor:HEX(10,86,214,1)];
            [lg drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:lab] angle:-70];
            [self label:@"V7" in:lab color:NSColor.whiteColor size:r.size.height*0.10];
            if(glow>0){ [[cyan colorWithAlphaComponent:glow] setStroke]; NSBezierPath *g=[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r,-3,-3)]; g.lineWidth=4;[g stroke]; }
            continue;
        }
        if ([c.kind isEqual:@"fader"]) {
            [self drawRoundRect:r radius:6 fill:HEX(20,25,34,1) stroke:HEX(36,44,58,1) width:1];
            CGFloat v = c.lastVal<0?0.5:(1.0-c.lastVal/127.0);
            NSRect cap=NSMakeRect(r.origin.x+2, r.origin.y+2+v*(r.size.height-r.size.height*0.14-4), r.size.width-4, r.size.height*0.14);
            [self drawRoundRect:cap radius:3 fill:(glow>0?cyan:accent) stroke:nil width:0];
            [self label:c.label in:NSMakeRect(r.origin.x-6,NSMaxY(r)+2,r.size.width+12,12) color:HEX(91,100,115,1) size:9];
            continue;
        }
        if ([c.kind isEqual:@"strip"]) {
            [self drawRoundRect:r radius:5 fill:HEX(20,25,34,1) stroke:HEX(36,44,58,1) width:1];
            if(c.lastVal>=0 && glow>0){ CGFloat x=r.origin.x+(c.lastVal/127.0)*(r.size.width-6);
                [[cyan colorWithAlphaComponent:glow] setFill]; NSRectFill(NSMakeRect(x,r.origin.y+2,6,r.size.height-4)); }
            [self label:c.label in:r color:HEX(91,100,115,1) size:9];
            continue;
        }
        // buttons / pads / knobs
        BOOL pad=[c.kind isEqual:@"pad"];
        CGFloat rad = ([c.kind isEqual:@"knob"]? r.size.height/2 : 7);
        NSColor *fill = HEX(20,25,34,1);
        NSColor *stroke = c.hasMap?HEX(51,64,90,1):HEX(36,44,58,1);
        if(c==_armed) stroke=HEX(217,150,58,1);
        if(glow>0) fill = (pad?hot:accent);
        [self drawRoundRect:r radius:rad fill:fill stroke:stroke width:(c==_armed?2:1)];
        [self label:c.label in:r color:(glow>0?NSColor.whiteColor:HEX(139,147,165,1)) size:10];
    }
}

// ---- persistence ----
- (void)loadMap {
    NSDictionary *m=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"map"];
    // default known: platter deck A = CC 0x00
    for(V7Control *c in _controls) if([c.cid isEqual:@"platter"]){ c.hasMap=YES; c.status=0xB0; c.d0=0x00; }
    for(V7Control *c in _controls){ NSString *v=m[c.cid]; if(v){ NSArray *p=[v componentsSeparatedByString:@","];
        if(p.count==2){ c.hasMap=YES; c.status=(uint8_t)[p[0] intValue]; c.d0=(uint8_t)[p[1] intValue]; } } }
}
- (void)saveMap {
    NSMutableDictionary *m=[NSMutableDictionary dictionary];
    for(V7Control *c in _controls) if(c.hasMap) m[c.cid]=[NSString stringWithFormat:@"%d,%d",c.status,c.d0];
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"map"];
}
- (void)clearMap { for(V7Control *c in _controls){ c.hasMap=NO; } [self loadMap]; [self saveMap]; self.needsDisplay=YES; }
- (NSString*)exportXML {
    NSMutableString *s=[NSMutableString stringWithString:@"<device name=\"Numark V7\" author=\"OpenV7\" type=\"MIDI\" decks=\"1\">\n"];
    for(V7Control *c in _controls) if(c.hasMap){
        if((c.status&0xF0)==0xE0) [s appendFormat:@"  <map value=\"0x%02x\" name=\"%@\" />\n",c.status,c.cid];
        else [s appendFormat:@"  <map value=\"0x%02x 0x%02x\" name=\"%@\" />\n",c.status,c.d0,c.cid];
    }
    [s appendString:@"</device>\n"]; return s;
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
@property (assign) BOOL connected;
@property (strong) NSTimer *timer2;
@property (strong) NSTextField *midiStat;
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
    if([self bridgeRunning]) return;
    NSString *path=[self bridgePath]; if(!path) return;
    NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:path];
    t.standardOutput=[NSFileHandle fileHandleWithNullDevice];
    t.standardError=[NSFileHandle fileHandleWithNullDevice];
    NSError *e=nil; if([t launchAndReturnError:&e]) _task=t;
    [self refresh];
}
- (void)stopBridge { if([self bridgeRunning]) [_task terminate]; _task=nil; }

- (void)connectMIDI {
    if(!_client) MIDIClientCreate(CFSTR("OpenV7 Tester"), NULL, NULL, &_client);
    if(!_inPort) MIDIInputPortCreate(_client, CFSTR("in"), MIDIReadCB, NULL, &_inPort);
    if(!_outPort) MIDIOutputPortCreate(_client, CFSTR("out"), &_outPort);
    MIDIEndpointRef src=findEndpointNamed(@"Numark V7", YES);
    _dest = findEndpointNamed(@"Numark V7", NO);
    if(src && !_connected){ MIDIPortConnectSource(_inPort, src, NULL); }
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
- (void)updateMidiStat {
    if(!_midiStat) return;
    _midiStat.stringValue = [NSString stringWithFormat:@"MIDI: %@ · %ld msgs in",
        _connected?@"connected":@"waiting for bridge…", g_rxcount];
    _midiStat.textColor = _connected ? HEX(59,189,138,1) : HEX(217,150,58,1);
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
    NSRect frame=NSMakeRect(0,0,900,620);
    _tester=[[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _tester.title=@"OpenV7 — Tester"; _tester.releasedWhenClosed=NO; [_tester center];
    _tester.minSize=NSMakeSize(760,520);
    NSView *cv=_tester.contentView;

    _dev=[[DeviceView alloc] initWithFrame:NSMakeRect(16,16,540,588)];
    _dev.autoresizingMask=NSViewHeightSizable|NSViewMaxXMargin; _dev.delegate=self;
    _dev.wantsLayer=YES; _dev.layer.cornerRadius=16; _dev.layer.masksToBounds=YES;
    [cv addSubview:_dev];

    CGFloat px=572, pw=312;
    _learnBtn=[NSButton buttonWithTitle:@"Learn mode: off" target:self action:@selector(toggleLearn:)];
    _learnBtn.frame=NSMakeRect(px,566,150,30); _learnBtn.bezelStyle=NSBezelStyleRounded; [cv addSubview:_learnBtn];
    NSButton *exp=[NSButton buttonWithTitle:@"Export map" target:self action:@selector(exportMap:)];
    exp.frame=NSMakeRect(px+156,566,pw-156,30); exp.bezelStyle=NSBezelStyleRounded; [cv addSubview:exp];

    // motor / output test buttons
    NSArray *tests=@[@[@"Motor ▶",@"start"],@[@"Brake ■",@"brake"],@[@"45",@"r45"],@[@"33",@"r33"]];
    CGFloat tx=px;
    for(NSArray *t in tests){ NSButton *b=[NSButton buttonWithTitle:t[0] target:self action:@selector(testOut:)];
        b.identifier=t[1]; b.frame=NSMakeRect(tx,526,72,28); b.bezelStyle=NSBezelStyleRounded; [cv addSubview:b]; tx+=76; }
    NSTextField *tl=[NSTextField labelWithString:@"Output test:"]; tl.frame=NSMakeRect(px,556,pw,16);
    tl.font=[NSFont systemFontOfSize:10]; tl.textColor=HEX(139,147,165,1); [cv addSubview:tl];

    _midiStat=[NSTextField labelWithString:@"MIDI: waiting for bridge…"];
    _midiStat.frame=NSMakeRect(px,490,pw,18); _midiStat.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    [cv addSubview:_midiStat]; [self updateMidiStat];

    NSScrollView *sv=[[NSScrollView alloc] initWithFrame:NSMakeRect(px,16,pw,466)];
    sv.hasVerticalScroller=YES; sv.borderType=NSLineBorder; sv.autoresizingMask=NSViewHeightSizable|NSViewMinXMargin;
    _log=[[NSTextView alloc] initWithFrame:sv.bounds]; _log.editable=NO; _log.drawsBackground=YES;
    _log.backgroundColor=HEX(10,13,19,1); _log.textContainerInset=NSMakeSize(6,6);
    sv.documentView=_log; [cv addSubview:sv];

    NSButton *cal=[NSButton buttonWithTitle:@"Calibration…" target:self action:@selector(openCalibration:)];
    cal.frame=NSMakeRect(px+156,526,pw-156,28); cal.bezelStyle=NSBezelStyleRounded; [cv addSubview:cal];

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
    NSArray *steps=@[
      @"Calibration is a HARDWARE procedure — do it with the USB cable UNPLUGGED. OpenV7 can't run it.",
      @"1. Unplug USB; power the V7 OFF.",
      @"2. Hold the RIGHT deck HOT CUE 1 + 3, then power ON. They flash twice = calibration mode.",
      @"3. Wait 10–20 seconds.",
      @"4. All faders/knobs to MAX (right), pitch faders to BOTTOM. Press LEFT HOT CUE 1 when lit.",
      @"5. All faders/knobs to MIN (left), pitch faders to TOP. Press LEFT HOT CUE 1 when lit.",
      @"6. Left strip: touch far-right, far-left, center — press HOT CUE 1 at each.",
      @"7. Right strip: repeat far-right, far-left, center — press HOT CUE 1 at each.",
      @"8. All controls to MIDDLE. Press LEFT HOT CUE 1.",
      @"9. LEFT HOT CUE 1–5 flash = complete.",
      @"10. Power-cycle before reconnecting USB. Then verify here in the Tester."
    ];
    NSAlert *a=[NSAlert new]; a.messageText=@"Numark V7 Calibration";
    a.informativeText=[steps componentsJoinedByString:@"\n\n"];
    [a addButtonWithTitle:@"Done"]; [a runModal];
}

// ---- menu bar ----
- (void)tick {
    if(![self bridgeRunning]) [self startBridge];
    if(!_connected) [self connectMIDI];
    [self refresh];
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
    if(getenv("OPENV7_OPEN_TESTER")) [self openTester:nil];   // test hook
}
- (void)applicationWillTerminate:(NSNotification*)n { (void)n; [self stopBridge]; }
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
