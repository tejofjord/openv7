// SPDX-License-Identifier: MIT
//
// OpenV7.app — a menu-bar wrapper around the openv7 bridge.
//
// Runs the bundled, self-contained `openv7-bridge` as a background child
// process, shows connection status in the menu bar, and offers a GUI
// "Open at Login" toggle. No Terminal, no Homebrew, no launchctl.

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSTask       *task;
@property (strong) NSTimer      *timer;
@property (strong) NSMenuItem   *statusLine;
@property (strong) NSMenuItem   *loginItem;
@end

@implementation AppDelegate

- (NSString *)bridgePath {
    return [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"openv7-bridge"];
}

- (BOOL)bridgeRunning {
    return self.task != nil && self.task.isRunning;
}

- (void)startBridge {
    if ([self bridgeRunning]) return;
    NSString *path = [self bridgePath];
    if (!path) return;
    NSTask *t = [[NSTask alloc] init];
    t.executableURL   = [NSURL fileURLWithPath:path];
    t.arguments       = @[];
    t.standardOutput  = [NSFileHandle fileHandleWithNullDevice];
    t.standardError   = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if ([t launchAndReturnError:&err]) self.task = t;   // exits by itself if no V7
    [self refresh];
}

- (void)stopBridge {
    if ([self bridgeRunning]) [self.task terminate];
    self.task = nil;
}

// Poll: the bridge exits when the V7 is absent/unplugged; relaunch so it
// reconnects automatically when the deck is plugged back in.
- (void)tick {
    if (![self bridgeRunning]) [self startBridge];
    else [self refresh];
}

- (void)refresh {
    BOOL up = [self bridgeRunning];
    self.item.button.title = up ? @"◉ V7" : @"○ V7";
    self.statusLine.title  = up ? @"Numark V7 — connected"
                                 : @"Numark V7 — not found (plug it in)";
    if (@available(macOS 13.0, *))
        self.loginItem.state = (SMAppService.mainAppService.status ==
                                SMAppServiceStatusEnabled) ? NSControlStateValueOn
                                                           : NSControlStateValueOff;
}

- (void)toggleLogin:(id)sender {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        SMAppService *svc = SMAppService.mainAppService;
        if (svc.status == SMAppServiceStatusEnabled) [svc unregisterAndReturnError:&err];
        else                                         [svc registerAndReturnError:&err];
    }
    [self refresh];
}

- (void)restart:(id)sender { [self stopBridge]; [self startBridge]; }
- (void)quit:(id)sender    { [self stopBridge]; [NSApp terminate:nil]; }

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title = @"○ V7";

    NSMenu *menu = [[NSMenu alloc] init];
    self.statusLine = [[NSMenuItem alloc] initWithTitle:@"Numark V7 — starting…" action:nil keyEquivalent:@""];
    self.statusLine.enabled = NO;
    [menu addItem:self.statusLine];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Restart bridge" action:@selector(restart:) keyEquivalent:@"r"];
    self.loginItem = [[NSMenuItem alloc] initWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    [menu addItem:self.loginItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit OpenV7" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *mi in menu.itemArray) if (mi.action) mi.target = self;
    self.item.menu = menu;

    [self startBridge];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                  target:self selector:@selector(tick)
                                                userInfo:nil repeats:YES];
    [self refresh];
}

- (void)applicationWillTerminate:(NSNotification *)note { (void)note; [self stopBridge]; }
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [[AppDelegate alloc] init];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];  // menu-bar only
        [app run];
    }
    return 0;
}
