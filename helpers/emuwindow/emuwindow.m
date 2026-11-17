// takwerx's window helper, loaded into takwerx's own copy of Google's emulator on the Mac by
// DYLD_INSERT_LIBRARIES from the launcher script (emu_bundle; the copy's entitlements allow
// it). The emulator has no full-screen mode: its main window has no green button. This
// marks that window full-screen capable, so macOS takes it full screen the usual way (its
// own Space, menu bar and Dock hidden); Ctrl+Cmd+F switches, F11 being macOS's Show Desktop.
// With TAKWERX_FULLSCREEN=1 the window goes full screen once it is up, Android having been
// sized to the screen for it (emu_geometry). The side toolbar is hidden while full screen.
// Every step is written to TAKWERX_WINDOW_LOG. Does nothing outside the emulator's own
// process, and takes itself out of the environment so its helpers do not load it.
// Build: build.sh (Xcode Command Line Tools); the built dylib is committed, users have no
// compiler.
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static NSString *logPath;
static BOOL wantFull;
static BOOL armed;         // full screen at start wanted and not yet asked for
static BOOL rearmOnActive; // asked, macOS did not, try again when next in front
static BOOL everFull;
static NSUInteger transitions; // full-screen entries and exits so far
static BOOL toldWaiting;
static NSTimeInterval seenAt;
static NSMutableArray *hiddenTools;
static NSMutableArray *detached;

static void note(NSString *format, ...) {
    if (!logPath) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], text];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!h) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

// The emulator's main window is its largest visible titled one; the side toolbar and
// Extended Controls are smaller, and the untitled screen-sized window macOS puts up during
// the full-screen animation is not the emulator's (the MacBook, 2026-09-29).
static NSWindow *mainWindow(void) {
    NSWindow *best = nil;
    CGFloat bestArea = 0;
    for (NSWindow *w in NSApp.windows) {
        if (!w.visible || !(w.styleMask & NSWindowStyleMaskTitled)) continue;
        CGFloat a = w.frame.size.width * w.frame.size.height;
        if (a > bestArea) { bestArea = a; best = w; }
    }
    return best;
}

static BOOL isFull(NSWindow *w) { return (w.styleMask & NSWindowStyleMaskFullScreen) != 0; }

static void makeCapable(NSWindow *w) {
    NSWindowCollectionBehavior b = w.collectionBehavior;
    NSWindowCollectionBehavior want = (b & ~(NSWindowCollectionBehaviorFullScreenAuxiliary |
                                             NSWindowCollectionBehaviorFullScreenNone)) |
                                      NSWindowCollectionBehaviorFullScreenPrimary;
    if (b != want) {
        w.collectionBehavior = want;
        note(@"window \"%@\" %@: full-screen capable (behavior 0x%lx -> 0x%lx, style 0x%lx, %lu child windows, parent %@)",
             w.title, NSStringFromRect(w.frame), (unsigned long)b, (unsigned long)want,
             (unsigned long)w.styleMask, (unsigned long)w.childWindows.count, w.parentWindow ? @"yes" : @"no");
    }
    // The title bar's three buttons, kept shown and enabled. The emulator starts its main
    // window with all three hidden (its side toolbar has its own close and minimize; the
    // Studio, 2026-10-09), and Qt 6.5 hides them again whenever it re-applies the window's
    // flags, as when the window moves between displays: on the MacBook with a second
    // display the window had none (2026-10-09), so no green button for full screen.
    NSWindowButton kinds[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
    NSString *names[] = { @"close", @"minimize", @"green" };
    for (int i = 0; i < 3; i++) {
        NSButton *button = [w standardWindowButton:kinds[i]];
        if (!button) continue;
        if (button.hidden) { button.hidden = NO; note(@"%@ button shown again", names[i]); }
        if (!button.enabled) { button.enabled = YES; note(@"%@ button enabled", names[i]); }
    }
}

static void showTools(void);

static void toggle(NSString *why) {
    NSWindow *w = mainWindow();
    if (!w) { note(@"%@: no window", why); return; }
    makeCapable(w);
    BOOL entering = !isFull(w);
    NSSize screen = w.screen.frame.size;
    note(@"%@: %@ full screen (window %@, content min %@ max %@, screen %@, app %@, delegate %@)",
         why, entering ? @"entering" : @"leaving", NSStringFromRect(w.frame),
         NSStringFromSize(w.contentMinSize), NSStringFromSize(w.contentMaxSize), NSStringFromSize(screen),
         NSApp.active ? @"active" : @"inactive", NSStringFromClass([w.delegate class]));
    if (entering) {
        // A maximum smaller than the screen makes macOS give up on the way in.
        if (w.contentMaxSize.width < screen.width || w.contentMaxSize.height < screen.height) {
            w.contentMaxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
            note(@"content maximum lifted");
        }
        // The side toolbar rides on the main window as a child window; macOS starts the
        // transition with one attached and does not finish it. Detached for the way in,
        // hidden while full screen, attached again on the way out.
        for (NSWindow *c in [w.childWindows copy]) {
            note(@"child window %@ detached", NSStringFromRect(c.frame));
            [w removeChildWindow:c];
            [detached addObject:c];
        }
    }
    [w toggleFullScreen:nil];
    if (entering) {
        NSUInteger before = transitions;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // In and out again already: the user's choice, not a failure.
            if (isFull(w) || transitions != before) return;
            note(@"not full screen 5 s later (window %@, app %@)", NSStringFromRect(w.frame), NSApp.active ? @"active" : @"inactive");
            showTools();
            if (wantFull && !everFull) rearmOnActive = YES;
        });
    }
}

// The toolbar would sit over the full-screen map, or next to it where there is no screen.
static void hideTools(NSWindow *main) {
    for (NSWindow *w in NSApp.windows) {
        if (w == main || !w.visible) continue;
        NSSize s = w.frame.size;
        if (s.width * 3 >= s.height) continue;
        [hiddenTools addObject:w];
        [w orderOut:nil];
        note(@"toolbar %@ hidden", NSStringFromRect(w.frame));
    }
}

// On a display whose shape differs from Android's, the emulator keeps the picture's
// proportions and its full-screen window comes out narrower than the screen, and macOS
// leaves it at the left edge: 1718 of the MB16A's 1920 points, a black strip on the right
// only (2026-10-09). Centred instead, the strip split between both sides. The full-screen
// area is the screen less a MacBook's notch band. Checked again after a moment, as the
// emulator may resize its window after the transition.
static void centre(NSWindow *w) {
    if (!isFull(w) || !w.screen) return;
    NSRect s = w.screen.frame, f = w.frame;
    CGFloat top = 0;
    if (@available(macOS 12.0, *)) top = w.screen.safeAreaInsets.top;
    CGFloat x = s.origin.x + floor((s.size.width - f.size.width) / 2);
    CGFloat y = s.origin.y + floor((s.size.height - top - f.size.height) / 2);
    if (fabs(f.origin.x - x) < 2 && fabs(f.origin.y - y) < 2) return;
    [w setFrameOrigin:NSMakePoint(x, y)];
    note(@"full screen: window %@ centred on screen %@, now %@", NSStringFromRect(f),
         NSStringFromRect(s), NSStringFromRect(w.frame));
}

static void showTools(void) {
    for (NSWindow *w in hiddenTools) [w orderFront:nil];
    if (hiddenTools.count) note(@"toolbar shown again");
    [hiddenTools removeAllObjects];
    NSWindow *main = mainWindow();
    for (NSWindow *c in detached) if (main && main != c) { [main addChildWindow:c ordered:NSWindowAbove]; note(@"child window attached again"); }
    [detached removeAllObjects];
}

// Cmd+V types the Mac's clipboard text into Android. The emulator's own clipboard sharing
// is unreliable here: on the MacBook a Mac copy reached Android once and then not again,
// while Chrome pasted what had come; in ATAK nothing pasted at all (2026-11-17). Typing
// needs neither. The text goes to the emulator's console (localhost, its auth token file)
// as `event text`, which turns characters into key presses. Measured on the Studio: a batch
// of more than about 30 key events (a capital is 4, a small letter 2) is dropped whole, and
// batches sent back to back drop parts, so 6 characters at a time, 60 ms apart (a 107-
// character tak:// link exact in about 1 s). A piece's leading spaces are dropped by the
// console and trailing ones kept, so spaces ride at the end of the piece before; those that
// start a line are sent as Space keys. A backslash is the console's escape: doubled. New
// lines are Enter, except at the end (a pasted password must not submit by itself).
static int consolePort;
static dispatch_queue_t typing;

static BOOL consoleReply(int fd) {
    char buf[512];
    NSMutableData *got = [NSMutableData data];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) return NO;
        [got appendBytes:buf length:(NSUInteger)n];
        NSString *s = [[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding] ?: @"";
        if ([s hasSuffix:@"OK\r\n"] || [s hasSuffix:@"OK\n"]) return YES;
        if ([s containsString:@"KO"]) { note(@"console: %@", [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]); return NO; }
    }
}

static BOOL consoleSend(int fd, NSString *cmd) {
    NSData *d = [[cmd stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (write(fd, d.bytes, d.length) != (ssize_t)d.length) return NO;
    return consoleReply(fd);
}

static NSArray<NSString *> *consolePieces(NSString *line) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger i = 0, len = line.length;
    while (i < len && [line characterAtIndex:i] == ' ') { [out addObject:@"event send EV_KEY:KEY_SPACE:1 EV_KEY:KEY_SPACE:0"]; i++; }
    while (i < len) {
        NSMutableString *piece = [NSMutableString string];
        int chars = 0;
        while (i < len && chars < 6) {
            NSRange r = [line rangeOfComposedCharacterSequenceAtIndex:i];
            NSString *c = [line substringWithRange:r];
            [piece appendString:[c isEqualToString:@"\\"] ? @"\\\\" : c];
            i = NSMaxRange(r);
            chars++;
        }
        while (i < len && [line characterAtIndex:i] == ' ') { [piece appendString:@" "]; i++; }
        [out addObject:[@"event text " stringByAppendingString:piece]];
    }
    return out;
}

static void typeClipboard(void) {
    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!text.length) { note(@"Cmd+V: no text on the Mac clipboard"); NSBeep(); return; }
    if (text.length > 4000) { note(@"Cmd+V: %lu characters, over 4000; not typed", (unsigned long)text.length); NSBeep(); return; }
    if (!consolePort) { note(@"Cmd+V: no console port (TAKWERX_CONSOLE_PORT)"); NSBeep(); return; }
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    while ([text hasSuffix:@"\n"]) text = [text substringToIndex:text.length - 1];
    NSString *chunk = [text copy];
    dispatch_async(typing, ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)consolePort) };
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        struct timeval tv = { .tv_sec = 3 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0 || !consoleReply(fd)) {
            note(@"Cmd+V: console on port %d not reachable", consolePort);
            if (fd >= 0) close(fd);
            return;
        }
        NSString *tokenPath = [NSHomeDirectory() stringByAppendingPathComponent:@".emulator_console_auth_token"];
        NSString *token = [[NSString stringWithContentsOfFile:tokenPath encoding:NSUTF8StringEncoding error:nil]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (token.length && !consoleSend(fd, [@"auth " stringByAppendingString:token])) {
            note(@"Cmd+V: console refused the token"); close(fd); return;
        }
        NSArray *lines = [chunk componentsSeparatedByString:@"\n"];
        NSUInteger sent = 0;
        BOOL ok = YES;
        for (NSUInteger l = 0; l < lines.count && ok; l++) {
            if (l > 0) ok = consoleSend(fd, @"event send EV_KEY:KEY_ENTER:1 EV_KEY:KEY_ENTER:0");
            for (NSString *cmd in consolePieces(lines[l])) {
                if (!ok) break;
                usleep(60000);
                ok = consoleSend(fd, cmd);
                sent++;
            }
        }
        consoleSend(fd, @"quit");
        close(fd);
        note(@"Cmd+V: typed %lu characters in %lu pieces%@", (unsigned long)chunk.length, (unsigned long)sent, ok ? @"" : @", stopped by an error");
    });
}

static void start(void) {
    hiddenTools = [NSMutableArray new];
    detached = [NSMutableArray new];
    typing = dispatch_queue_create("takwerx.typing", DISPATCH_QUEUE_SERIAL);
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
                                 ~(NSEventModifierFlagCapsLock | NSEventModifierFlagNumericPad);
        BOOL ctrlCmd = m == (NSEventModifierFlagControl | NSEventModifierFlagCommand);
        BOOL globe = m == NSEventModifierFlagFunction;
        if (e.keyCode == 3 /* kVK_ANSI_F */ && (ctrlCmd || globe)) {
            toggle(ctrlCmd ? @"Ctrl+Cmd+F" : @"Globe+F");
            return nil;
        }
        // Not in Extended Controls, which has text fields of its own. Not "only the main
        // window" either: full screen on the MacBook, the event's window was not the one
        // mainWindow() picks, and Cmd+V did nothing (2026-11-17).
        if (e.keyCode == 9 /* kVK_ANSI_V */ && m == NSEventModifierFlagCommand) {
            NSWindow *k = e.window ?: NSApp.keyWindow;
            BOOL extended = [k.title rangeOfString:@"Extended" options:NSCaseInsensitiveSearch].location != NSNotFound;
            note(@"Cmd+V in window \"%@\" %@ (main window %@)%@", k.title, NSStringFromRect(k.frame),
                 NSStringFromRect(mainWindow().frame), extended ? @": Extended Controls, left alone" : @"");
            if (extended) return e;
            typeClipboard();
            return nil;
        }
        return e;
    }];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSWindowWillEnterFullScreenNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        note(@"macOS is taking the window full screen");
    }];
    [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        everFull = YES;
        transitions++;
        NSWindow *w = n.object;
        note(@"full screen: window %@", NSStringFromRect(w.frame));
        hideTools(w);
        centre(w);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ centre(w); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ centre(w); });
    }];
    [nc addObserverForName:NSWindowWillExitFullScreenNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        note(@"macOS is taking the window out of full screen");
    }];
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        note(@"app active");
        if (rearmOnActive) { rearmOnActive = NO; armed = YES; }
    }];
    [nc addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        transitions++;
        note(@"full screen off: window %@", NSStringFromRect(((NSWindow *)n.object).frame));
        showTools();
    }];
    // The main window is marked as it appears, and again should Qt reset it. The first
    // full screen waits two seconds after it appears, for the emulator to place it, and for
    // the app to be in front: macOS begins the transition for an app that is not and never
    // finishes it (2026-09-29), and refuses an app that brings itself forward. So a click
    // into the window, or on its Dock icon, is what takes it full screen.
    armed = wantFull;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        NSWindow *w = mainWindow();
        if (!w || w.frame.size.width < 200) return;
        makeCapable(w);
        // Something put the window back at the left edge half a second after the first
        // centring on the MB16A; kept centred for the whole session, not just its entry.
        centre(w);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!seenAt) seenAt = now;
        if (!armed || now - seenAt < 2) return;
        if (!NSApp.active) {
            if (!toldWaiting) { toldWaiting = YES; note(@"full screen waits for the window to be in front"); }
            return;
        }
        armed = NO;
        if (!isFull(w)) toggle(@"start");
    }];
    note(@"window helper loaded (full screen at start: %@)", wantFull ? @"yes" : @"no");
}

__attribute__((constructor)) static void takwerxWindowInit(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char *name = getprogname();
    if (!name || !strstr(name, "qemu-system")) return;
    const char *lp = getenv("TAKWERX_WINDOW_LOG");
    if (lp && *lp) logPath = [NSString stringWithUTF8String:lp];
    const char *fs = getenv("TAKWERX_FULLSCREEN");
    wantFull = fs && strcmp(fs, "1") == 0;
    const char *cp = getenv("TAKWERX_CONSOLE_PORT");
    consolePort = cp ? atoi(cp) : 0;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                      object:nil queue:nil usingBlock:^(NSNotification *n) {
        start();
    }];
}
