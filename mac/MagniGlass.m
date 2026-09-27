// MagniGlass for macOS: a realistic magnifying glass (real glass, chrome rim and grip)
// that follows the pointer. Menu bar app; a global shortcut shows / hides the glass and
// the scroll wheel zooms while it is shown. The glass is drawn by the shared C renderer
// (core/lenscore.c); the screen comes from ScreenCaptureKit with MagniGlass itself
// excluded, so the glass never magnifies its own reflection.
//
//   MagniGlass.app/Contents/MacOS/MagniGlass --render-test out.png   (CI: render the lens, exit)

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <os/lock.h>

#include "../core/lenscore.h"

static const double kMinZoom = 1.0, kMaxZoom = 10.0;
static const NSInteger kMinPoints = 80, kMaxPoints = 1600, kMinPercent = 5, kMaxPercent = 90;

// ---------------------------------------------------------------------------------------
#pragma mark - Settings

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }

static void RegisterDefaults(void) {
    [Defaults() registerDefaults:@{
        @"hotkeyCode": @(kVK_ANSI_M),
        @"hotkeyMods": @(controlKey | optionKey),
        @"hotkeyKeyName": @"M",
        @"sizeUnit": @"px",       // "px" (points) or "percent" (of the screen's shorter side)
        @"sizePoints": @320,
        @"sizePercent": @30,
        @"zoom": @2.5,
        @"wheelZoom": @YES,
        @"wheelModifier": @"none", // none, control, option, shift, command
        @"wheelStep": @15,        // % per notch
        @"handleLeft": @NO,
        @"shadow": @YES,
        @"firstRun": @YES,
    }];
}

static NSString *HotkeyDescription(UInt32 mods, NSString *key) {
    NSMutableString *s = [NSMutableString string];
    if (mods & controlKey) [s appendString:@"⌃"];
    if (mods & optionKey) [s appendString:@"⌥"];
    if (mods & shiftKey) [s appendString:@"⇧"];
    if (mods & cmdKey) [s appendString:@"⌘"];
    [s appendString:key ?: @"?"];
    return s;
}

static NSString *CurrentHotkeyDescription(void) {
    return HotkeyDescription((UInt32)[Defaults() integerForKey:@"hotkeyMods"], [Defaults() stringForKey:@"hotkeyKeyName"]);
}

static NSString *KeyName(unsigned short code, NSString *chars) {
    switch (code) {
        case kVK_Space: return @"Space";
        case kVK_Return: return @"↩";
        case kVK_Tab: return @"⇥";
        case kVK_Delete: return @"⌫";
        case kVK_ForwardDelete: return @"⌦";
        case kVK_Escape: return @"⎋";
        case kVK_LeftArrow: return @"←";
        case kVK_RightArrow: return @"→";
        case kVK_UpArrow: return @"↑";
        case kVK_DownArrow: return @"↓";
        case kVK_Home: return @"↖";
        case kVK_End: return @"↘";
        case kVK_PageUp: return @"⇞";
        case kVK_PageDown: return @"⇟";
        case kVK_F1: return @"F1"; case kVK_F2: return @"F2"; case kVK_F3: return @"F3"; case kVK_F4: return @"F4";
        case kVK_F5: return @"F5"; case kVK_F6: return @"F6"; case kVK_F7: return @"F7"; case kVK_F8: return @"F8";
        case kVK_F9: return @"F9"; case kVK_F10: return @"F10"; case kVK_F11: return @"F11"; case kVK_F12: return @"F12";
        case kVK_F13: return @"F13"; case kVK_F14: return @"F14"; case kVK_F15: return @"F15"; case kVK_F16: return @"F16";
        case kVK_F17: return @"F17"; case kVK_F18: return @"F18"; case kVK_F19: return @"F19"; case kVK_F20: return @"F20";
        default: break;
    }
    return chars.length ? chars.uppercaseString : [NSString stringWithFormat:@"#%d", code];
}

static BOOL IsFunctionKey(unsigned short code) {
    switch (code) {
        case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5: case kVK_F6: case kVK_F7: case kVK_F8:
        case kVK_F9: case kVK_F10: case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14: case kVK_F15:
        case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20: return YES;
        default: return NO;
    }
}

static int LensFlags(void) {
    return ([Defaults() boolForKey:@"handleLeft"] ? LENS_HANDLE_LEFT : 0) | ([Defaults() boolForKey:@"shadow"] ? 0 : LENS_NO_SHADOW);
}

/// Glass diameter in device pixels on a screen.
static int DiameterFor(NSScreen *screen) {
    CGFloat scale = screen.backingScaleFactor;
    NSSize sz = screen.frame.size;
    double d;
    if ([[Defaults() stringForKey:@"sizeUnit"] isEqualToString:@"percent"])
        d = MIN(sz.width, sz.height) * scale * [Defaults() integerForKey:@"sizePercent"] / 100.0;
    else
        d = [Defaults() integerForKey:@"sizePoints"] * scale;
    return (int)MAX(32, MIN(4096, lround(d)));
}

/// Draws the lens rows, split across cores for big lenses.
static void DrawGlass(LensCtx *lens, int diameter, const uint8_t *src, int w, int h, size_t stride, int cx, int cy,
                      uint8_t *dst, int dstStride) {
    int top = lens_glass_top(lens), rows = lens_glass_bottom(lens) - top;
    int parts = diameter >= 360 ? 4 : 1;
    if (parts == 1) {
        lens_draw_glass(lens, src, w, h, (int)stride, cx, cy, dst, dstStride, top, top + rows);
        return;
    }
    dispatch_apply((size_t)parts, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
        int y0 = top + rows * (int)i / parts, y1 = top + rows * ((int)i + 1) / parts;
        lens_draw_glass(lens, src, w, h, (int)stride, cx, cy, dst, dstStride, y0, y1);
    });
}

// ---------------------------------------------------------------------------------------
#pragma mark - Updates (GitHub Releases, as in RailSaver)

static NSString *const kFeedRepo = @"vagdesign/MagniGlass";

static NSString *AppVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.0.0";
}

/// YES if version a (x.y.z) is newer than b.
static BOOL VersionNewer(NSString *a, NSString *b) {
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."], *pb = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < 3; i++) {
        NSInteger x = i < pa.count ? pa[i].integerValue : 0, y = i < pb.count ? pb[i].integerValue : 0;
        if (x != y) return x > y;
    }
    return NO;
}

/// Asks GitHub for the latest release. On the main queue: latest version, the Mac zip (or the
/// release page) to download, and an error text when the check failed.
static void CheckForUpdate(void (^done)(NSString *latest, NSURL *download, NSString *error)) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kFeedRepo]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"MagniGlass/%@", AppVersion()] forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSString *latest = nil, *err = nil;
        NSURL *download = nil;
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSDictionary *json = data && status == 200 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            NSString *tag = [json[@"tag_name"] description];
            latest = [tag hasPrefix:@"v"] || [tag hasPrefix:@"V"] ? [tag substringFromIndex:1] : tag;
            for (NSDictionary *a in json[@"assets"]) {
                NSString *name = [a[@"name"] description];
                if ([name rangeOfString:@"mac" options:NSCaseInsensitiveSearch].location != NSNotFound && [name.lowercaseString hasSuffix:@".zip"])
                    download = [NSURL URLWithString:[a[@"browser_download_url"] description]];
            }
            if (!download && json[@"html_url"]) download = [NSURL URLWithString:[json[@"html_url"] description]];
        } else {
            err = error ? error.localizedDescription : [NSString stringWithFormat:@"GitHub answered %ld", (long)status];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(latest, download, err); });
    }] resume];
}

static NSURL *ReleasesPage(void) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/releases/latest", kFeedRepo]];
}

// ---------------------------------------------------------------------------------------
#pragma mark - Sample page (settings preview, render test)

/// A light "document" with text and colour bars, in a BGRA premultiplied bitmap context.
static CGContextRef CreateSamplePage(int w, int h, CGFloat scale) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = g;
    [[NSColor colorWithSRGBRed:0.98 green:0.98 blue:0.97 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    NSDictionary *title = @{NSFontAttributeName: [NSFont systemFontOfSize:20 * scale weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.16 green:0.16 blue:0.18 alpha:1]};
    NSDictionary *body = @{NSFontAttributeName: [NSFont systemFontOfSize:12 * scale],
                           NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.40 green:0.40 blue:0.44 alpha:1]};
    [@"The quick brown fox" drawAtPoint:NSMakePoint(14 * scale, 10 * scale) withAttributes:title];
    NSString *text = @"MagniGlass follows your pointer with a real lens: fine print, icons and pixels come up large and sharp, "
                     @"the edge of the glass bends the page like a real magnifier and the chrome catches the light. "
                     @"Scroll to zoom in and out. 0123456789 · ABCDEFGHIJKLMNOPQRSTUVWXYZ · abcdefghijklmnopqrstuvwxyz";
    [text drawInRect:NSMakeRect(14 * scale, 44 * scale, w - 28 * scale, h * 0.5) withAttributes:body];
    NSArray<NSColor *> *sw = @[[NSColor colorWithSRGBRed:0.90 green:0.22 blue:0.27 alpha:1],
                               [NSColor colorWithSRGBRed:0.96 green:0.64 blue:0.38 alpha:1],
                               [NSColor colorWithSRGBRed:0.91 green:0.77 blue:0.42 alpha:1],
                               [NSColor colorWithSRGBRed:0.16 green:0.62 blue:0.56 alpha:1],
                               [NSColor colorWithSRGBRed:0.15 green:0.27 blue:0.33 alpha:1],
                               [NSColor colorWithSRGBRed:0.27 green:0.48 blue:0.62 alpha:1]];
    CGFloat bw = (w - 28 * scale) / sw.count;
    for (NSUInteger i = 0; i < sw.count; i++) {
        CGFloat bh = h * (0.12 + 0.05 * ((i * 7) % 5));
        [sw[i] setFill];
        NSRectFill(NSMakeRect(14 * scale + i * bw + 3 * scale, h - 12 * scale - bh, bw - 6 * scale, bh));
    }
    [NSGraphicsContext restoreGraphicsState];
    return ctx;
}

/// The lens drawn over the sample page; the caller releases the image.
static CGImageRef CreatePreviewImage(int w, int h, CGFloat scale, int diameter, double zoom, int flags) {
    CGContextRef page = CreateSamplePage(w, h, scale);
    LensCtx *lens = lens_create(diameter, (float)zoom, flags);
    int W = lens_width(lens), H = lens_height(lens);
    int cx = (flags & LENS_HANDLE_LEFT) ? (int)(w * 0.62) : (int)(w * 0.38), cy = (int)(h * 0.40);
    uint8_t *buf = calloc((size_t)W * H, 4);
    lens_draw_static(lens, buf, W * 4);
    DrawGlass(lens, diameter, CGBitmapContextGetData(page), w, h, CGBitmapContextGetBytesPerRow(page), cx, cy, buf, W * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef lc = CGBitmapContextCreate(buf, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef lensImage = CGBitmapContextCreateImage(lc);
    CGImageRef pageImage = CGBitmapContextCreateImage(page);
    CGContextRef out = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(out, CGRectMake(0, 0, w, h), pageImage);
    // bitmap contexts are bottom-up: flip the lens position
    CGContextDrawImage(out, CGRectMake(cx - lens_center_x(lens), h - (cy - lens_center_y(lens)) - H, W, H), lensImage);
    CGImageRef result = CGBitmapContextCreateImage(out);
    CGContextRelease(out);
    CGImageRelease(pageImage);
    CGImageRelease(lensImage);
    CGContextRelease(lc);
    CGColorSpaceRelease(cs);
    free(buf);
    lens_destroy(lens);
    CGContextRelease(page);
    return result;
}

// ---------------------------------------------------------------------------------------
#pragma mark - The glass window

@interface LensWindow : NSWindow
@end

@implementation LensWindow
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; } // may hang off screen edges
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface Magnifier : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) double zoom;
@property(nonatomic, readonly) BOOL visible;
- (void)show;
- (void)hide;
- (void)settingsChanged;
@end

@implementation Magnifier {
    LensWindow *_window;
    NSTimer *_timer;
    LensCtx *_lens;
    int _diameter, _flags;
    uint8_t *_frame;
    CGContextRef _frameCtx;
    CGColorSpaceRef _colorSpace;

    SCStream *_stream;
    CGDirectDisplayID _streamDisplay;
    BOOL _starting;
    dispatch_queue_t _queue;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest; // guarded by _lock
    BOOL _needsRebuild;
    BOOL _permissionAsked;
    CFTimeInterval _lastStart;
}

- (instancetype)init {
    if ((self = [super init])) {
        _zoom = [Defaults() doubleForKey:@"zoom"];
        _queue = dispatch_queue_create("MagniGlass.capture", DISPATCH_QUEUE_SERIAL);
        _lock = OS_UNFAIR_LOCK_INIT;
        _window = [[LensWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
        _window.opaque = NO;
        _window.backgroundColor = NSColor.clearColor;
        _window.hasShadow = NO;
        _window.ignoresMouseEvents = YES;
        _window.level = NSScreenSaverWindowLevel; // above menus and the Dock
        _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        _window.releasedWhenClosed = NO;
        // Layer-hosting view: AppKit never draws into it, the lens image is its contents.
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        CALayer *layer = [CALayer layer];
        layer.contentsGravity = kCAGravityResize;
        layer.actions = @{@"contents": [NSNull null], @"bounds": [NSNull null], @"position": [NSNull null]};
        view.layer = layer;
        view.wantsLayer = YES;
        _window.contentView = view;
    }
    return self;
}

- (void)setZoom:(double)zoom {
    _zoom = MAX(kMinZoom, MIN(kMaxZoom, zoom));
}

- (void)settingsChanged {
    _needsRebuild = YES;
}

- (void)show {
    if (_visible) return;
    if (!CGPreflightScreenCaptureAccess()) {
        if (!_permissionAsked) {
            _permissionAsked = YES;
            CGRequestScreenCaptureAccess(); // system prompt (first time) and the Privacy list entry
        }
        [self explainPermission];
        return;
    }
    _visible = YES;
    _timer = [NSTimer timerWithTimeInterval:1.0 / 120.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [self tick];
}

- (void)hide {
    if (!_visible) return;
    _visible = NO;
    [_timer invalidate];
    _timer = nil;
    [_window orderOut:nil];
    [self stopStream];
    [self freeLens];
}

- (void)explainPermission {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"MagniGlass needs Screen Recording permission";
    a.informativeText = @"To magnify what is under the pointer, MagniGlass reads the screen (nothing is saved or sent anywhere).\n\n"
                        @"Turn on MagniGlass in System Settings › Privacy & Security › Screen & System Audio Recording, "
                        @"then quit and reopen MagniGlass.";
    [a addButtonWithTitle:@"Open System Settings"];
    [a addButtonWithTitle:@"Later"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] == NSAlertFirstButtonReturn)
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

- (void)freeLens {
    if (_lens) lens_destroy(_lens);
    _lens = NULL;
    if (_frameCtx) CGContextRelease(_frameCtx);
    _frameCtx = NULL;
    free(_frame);
    _frame = NULL;
}

static NSScreen *ScreenWithMouse(NSPoint p) {
    for (NSScreen *s in NSScreen.screens)
        if (NSMouseInRect(p, s.frame, NO)) return s;
    return NSScreen.mainScreen;
}

static CGDirectDisplayID DisplayIDOf(NSScreen *s) {
    return [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

- (void)tick {
    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = ScreenWithMouse(mouse);
    if (!screen) return;
    CGFloat scale = screen.backingScaleFactor;
    CGDirectDisplayID display = DisplayIDOf(screen);
    if (!_starting && (display != _streamDisplay || !_stream) && CACurrentMediaTime() - _lastStart > 1.0)
        [self startStreamFor:display];

    int diameter = DiameterFor(screen), flags = LensFlags();
    if (!_lens || _needsRebuild || diameter != _diameter || flags != _flags) {
        _needsRebuild = NO;
        [self freeLens];
        _lens = lens_create(diameter, (float)_zoom, flags);
        if (!_lens) return;
        _diameter = diameter;
        _flags = flags;
        int W = lens_width(_lens), H = lens_height(_lens);
        _frame = calloc((size_t)W * H, 4);
        lens_draw_static(_lens, _frame, W * 4);
        if (_colorSpace) CGColorSpaceRelease(_colorSpace);
        // Tag the output with the display's own colour space: the captured pixels go
        // back to the same display untouched.
        _colorSpace = CGDisplayCopyColorSpace(display) ?: CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _frameCtx = CGBitmapContextCreate(_frame, W, H, 8, (size_t)W * 4, _colorSpace,
                                          kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    }
    lens_set_zoom(_lens, (float)_zoom);

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef pb = _latest ? CVPixelBufferRetain(_latest) : NULL;
    os_unfair_lock_unlock(&_lock);
    if (!pb) return; // first frame not here yet

    int W = lens_width(_lens), H = lens_height(_lens);
    int bw = (int)CVPixelBufferGetWidth(pb), bh = (int)CVPixelBufferGetHeight(pb);
    NSRect sf = screen.frame;
    // Pointer in device pixels, snapped so the glass sits on whole pixels.
    double px = floor((mouse.x - sf.origin.x) * scale), py = floor((NSMaxY(sf) - mouse.y) * scale);
    int sx = (int)lround(px * bw / (sf.size.width * scale)), sy = (int)lround(py * bh / (sf.size.height * scale));

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    if (base) DrawGlass(_lens, _diameter, base, bw, bh, CVPixelBufferGetBytesPerRow(pb), sx, sy, _frame, W * 4);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pb);

    CGImageRef image = CGBitmapContextCreateImage(_frameCtx); // copy-on-write snapshot
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _window.contentView.layer.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);

    NSRect frame = NSMakeRect(sf.origin.x + (px - lens_center_x(_lens)) / scale,
                              NSMaxY(sf) - (py - lens_center_y(_lens) + H) / scale,
                              W / scale, H / scale);
    [_window setFrame:frame display:NO];
    if (!_window.visible) [_window orderFrontRegardless];
}

// ---- ScreenCaptureKit ----

- (void)startStreamFor:(CGDirectDisplayID)displayID {
    [self stopStream];
    _streamDisplay = displayID;
    _starting = YES;
    _lastStart = CACurrentMediaTime();
    pid_t me = getpid();
    NSInteger windowNumber = _window.windowNumber;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self didGetContent:content error:error display:displayID pid:me window:windowNumber];
        });
    }];
}

- (void)didGetContent:(SCShareableContent *)content error:(NSError *)error display:(CGDirectDisplayID)displayID
                  pid:(pid_t)pid window:(NSInteger)windowNumber {
    if (!_visible || displayID != _streamDisplay) { _starting = NO; return; }
    if (!content) {
        NSLog(@"MagniGlass: no shareable content: %@", error);
        _starting = NO;
        [self hide];
        [self explainPermission];
        return;
    }
    SCDisplay *display = nil;
    for (SCDisplay *d in content.displays)
        if (d.displayID == displayID) display = d;
    if (!display) { _starting = NO; return; }

    SCContentFilter *filter = nil;
    for (SCRunningApplication *app in content.applications) {
        if (app.processID == pid) {
            filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:@[app] exceptingWindows:@[]];
            break;
        }
    }
    if (!filter) {
        NSMutableArray<SCWindow *> *mine = [NSMutableArray array];
        for (SCWindow *w in content.windows)
            if (w.windowID == (CGWindowID)windowNumber || w.owningApplication.processID == pid) [mine addObject:w];
        filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:mine];
    }

    NSScreen *screen = nil;
    for (NSScreen *s in NSScreen.screens)
        if (DisplayIDOf(s) == displayID) screen = s;
    CGFloat scale = screen ? screen.backingScaleFactor : 2.0;

    SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
    cfg.width = (size_t)lround(display.width * scale);
    cfg.height = (size_t)lround(display.height * scale);
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.showsCursor = NO;
    cfg.minimumFrameInterval = CMTimeMake(1, 60);
    cfg.queueDepth = 4;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:self];
    NSError *addError = nil;
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&addError]) {
        NSLog(@"MagniGlass: addStreamOutput failed: %@", addError);
        _starting = NO;
        return;
    }
    _stream = stream;
    [stream startCaptureWithCompletionHandler:^(NSError *startError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_starting = NO;
            if (startError) {
                NSLog(@"MagniGlass: capture failed: %@", startError);
                if (self->_stream == stream) self->_stream = nil;
            }
        });
    }];
}

- (void)stopStream {
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:nil];
        _stream = nil;
    }
    _streamDisplay = 0;
    os_unfair_lock_lock(&_lock);
    if (_latest) CVPixelBufferRelease(_latest);
    _latest = NULL;
    os_unfair_lock_unlock(&_lock);
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *status = info[SCStreamFrameInfoStatus];
        if (status && status.integerValue != SCFrameStatusComplete) return; // idle frames repeat the last one
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;
    CVPixelBufferRetain(pb);
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _latest;
    _latest = pb;
    os_unfair_lock_unlock(&_lock);
    if (old) CVPixelBufferRelease(old);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"MagniGlass: stream stopped: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stream == stream) {
            self->_stream = nil;
            self->_streamDisplay = 0; // the next tick restarts it
        }
    });
}

@end

// ---------------------------------------------------------------------------------------
#pragma mark - Shortcut recorder

@interface ShortcutField : NSButton
@property(nonatomic, copy) void (^onChange)(UInt32 mods, unsigned short code, NSString *name);
@property(nonatomic, copy) void (^onRecording)(BOOL recording);
- (void)showMods:(UInt32)mods name:(NSString *)name;
@end

@implementation ShortcutField {
    id _monitor;
    NSString *_shown;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bezelStyle = NSBezelStyleRounded;
        self.target = self;
        self.action = @selector(startRecording);
    }
    return self;
}

- (void)showMods:(UInt32)mods name:(NSString *)name {
    _shown = HotkeyDescription(mods, name);
    self.title = _shown;
}

- (void)startRecording {
    if (_monitor) return;
    self.title = @"Type the new shortcut…";
    if (self.onRecording) self.onRecording(YES);
    __weak ShortcutField *weakSelf = self;
    _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        return [weakSelf handle:e];
    }];
}

- (NSEvent *)handle:(NSEvent *)e {
    if (e.keyCode == kVK_Escape && !(e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagFunction)) {
        [self stop];
        self.title = _shown;
        return nil;
    }
    NSEventModifierFlags f = e.modifierFlags;
    UInt32 mods = 0;
    if (f & NSEventModifierFlagControl) mods |= controlKey;
    if (f & NSEventModifierFlagOption) mods |= optionKey;
    if (f & NSEventModifierFlagShift) mods |= shiftKey;
    if (f & NSEventModifierFlagCommand) mods |= cmdKey;
    BOOL hasMain = (mods & (controlKey | optionKey | cmdKey)) != 0;
    if (!hasMain && !IsFunctionKey(e.keyCode)) {
        NSBeep(); // a plain letter would stop working in every app
        return nil;
    }
    NSString *name = KeyName(e.keyCode, e.charactersIgnoringModifiers);
    [self stop];
    [self showMods:mods name:name];
    if (self.onChange) self.onChange(mods, e.keyCode, name);
    return nil;
}

- (void)stop {
    if (_monitor) [NSEvent removeMonitor:_monitor];
    _monitor = nil;
    if (self.onRecording) self.onRecording(NO);
}

- (void)viewDidMoveToWindow {
    if (!self.window) [self stop];
}

@end

// ---------------------------------------------------------------------------------------
#pragma mark - Settings window

@interface SettingsController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, copy) void (^onChange)(void);
@property(nonatomic, copy) void (^onShortcut)(UInt32 mods, unsigned short code, NSString *name);
@property(nonatomic, copy) void (^onRecording)(BOOL recording);
- (void)show;
- (void)showZoom:(double)zoom;
@end

@implementation SettingsController {
    ShortcutField *_shortcut;
    NSTextField *_shortcutNote, *_size, *_zoomText, *_permission;
    NSStepper *_sizeStepper;
    NSPopUpButton *_unit, *_wheelMod, *_handle;
    NSSlider *_zoom;
    NSButton *_wheel, *_shadow, *_login, *_permissionButton;
    NSTextField *_wheelStep;
    NSImageView *_preview;
    NSTextField *_updStatus;
    NSButton *_updCheck, *_updDownload;
    NSURL *_updURL;
}

static NSTextField *Label(NSString *s) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.alignment = NSTextAlignmentRight;
    return l;
}

static NSStackView *Row(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 8;
    s.alignment = NSLayoutAttributeFirstBaseline;
    return s;
}

- (void)build {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 600)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"MagniGlass Settings";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;

    __weak SettingsController *weakSelf = self;
    _shortcut = [[ShortcutField alloc] initWithFrame:NSMakeRect(0, 0, 200, 28)];
    [_shortcut.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    _shortcut.onChange = ^(UInt32 mods, unsigned short code, NSString *name) {
        SettingsController *me = weakSelf;
        if (me.onShortcut) me.onShortcut(mods, code, name);
    };
    _shortcut.onRecording = ^(BOOL recording) {
        SettingsController *me = weakSelf;
        if (me.onRecording) me.onRecording(recording);
    };
    NSButton *resetKey = [NSButton buttonWithTitle:@"Default" target:self action:@selector(resetShortcut)];
    _shortcutNote = [NSTextField wrappingLabelWithString:@"Click the button and press the new keys. Press it anywhere to show or hide the glass."];
    _shortcutNote.textColor = NSColor.secondaryLabelColor;
    _shortcutNote.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [_shortcutNote.widthAnchor constraintEqualToConstant:360].active = YES;

    _size = [NSTextField textFieldWithString:@""];
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.allowsFloats = NO;
    nf.minimum = @1;
    _size.formatter = nf;
    [_size.widthAnchor constraintEqualToConstant:70].active = YES;
    _size.target = self;
    _size.action = @selector(sizeEdited);
    _sizeStepper = [[NSStepper alloc] init];
    _sizeStepper.target = self;
    _sizeStepper.action = @selector(sizeStepped);
    _sizeStepper.valueWraps = NO;
    _unit = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_unit addItemsWithTitles:@[@"points (pixels)", @"% of the screen"]];
    _unit.target = self;
    _unit.action = @selector(unitChanged);

    _zoom = [NSSlider sliderWithValue:2.5 minValue:kMinZoom maxValue:kMaxZoom target:self action:@selector(zoomChanged)];
    _zoom.numberOfTickMarks = 10;
    [_zoom.widthAnchor constraintEqualToConstant:260].active = YES;
    _zoomText = [NSTextField labelWithString:@"2.5×"];
    _zoomText.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];

    _wheel = [NSButton checkboxWithTitle:@"Scroll wheel changes the magnification while the glass is shown" target:self action:@selector(changed)];
    _wheelMod = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_wheelMod addItemsWithTitles:@[@"no key needed", @"⌃ Control", @"⌥ Option", @"⇧ Shift", @"⌘ Command"]];
    _wheelMod.target = self;
    _wheelMod.action = @selector(changed);
    _wheelStep = [NSTextField textFieldWithString:@"15"];
    NSNumberFormatter *sf = [[NSNumberFormatter alloc] init];
    sf.allowsFloats = NO;
    sf.minimum = @5;
    sf.maximum = @50;
    _wheelStep.formatter = sf;
    [_wheelStep.widthAnchor constraintEqualToConstant:44].active = YES;
    _wheelStep.target = self;
    _wheelStep.action = @selector(changed);

    _handle = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_handle addItemsWithTitles:@[@"Lower right", @"Lower left"]];
    _handle.target = self;
    _handle.action = @selector(changed);
    _shadow = [NSButton checkboxWithTitle:@"Drop shadow" target:self action:@selector(changed)];

    _login = [NSButton checkboxWithTitle:@"Open MagniGlass when I log in" target:self action:@selector(loginChanged)];
    if (@available(macOS 13.0, *)) {
    } else {
        _login.enabled = NO;
        _login.title = @"Open at login: add MagniGlass in System Settings › General › Login Items";
    }

    _permission = [NSTextField labelWithString:@""];
    _permissionButton = [NSButton buttonWithTitle:@"Open System Settings" target:self action:@selector(openPrivacy)];

    _preview = [NSImageView imageViewWithImage:[[NSImage alloc] initWithSize:NSMakeSize(440, 260)]];
    _preview.imageScaling = NSImageScaleNone;
    _preview.wantsLayer = YES;
    _preview.layer.borderWidth = 1;
    _preview.layer.borderColor = NSColor.separatorColor.CGColor;
    [_preview.widthAnchor constraintEqualToConstant:440].active = YES;
    [_preview.heightAnchor constraintEqualToConstant:260].active = YES;

    _updStatus = [NSTextField labelWithString:@"Not checked yet."];
    _updCheck = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkUpdates)];
    _updDownload = [NSButton buttonWithTitle:@"Download" target:self action:@selector(downloadUpdate)];
    _updDownload.bezelColor = NSColor.controlAccentColor;
    _updDownload.hidden = YES;
    NSTextField *installed = [NSTextField labelWithString:[NSString stringWithFormat:@"Installed %@ ·", AppVersion()]];
    installed.textColor = NSColor.secondaryLabelColor;

    NSView *credits = [self creditsView];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[Label(@"Shortcut:"), Row(@[_shortcut, resetKey])],
        @[NSGridCell.emptyContentView, _shortcutNote],
        @[Label(@"Glass size:"), Row(@[_size, _sizeStepper, _unit])],
        @[Label(@"Magnification:"), Row(@[_zoom, _zoomText])],
        @[NSGridCell.emptyContentView, _wheel],
        @[Label(@"Wheel:"), Row(@[[NSTextField labelWithString:@"hold"], _wheelMod, [NSTextField labelWithString:@"step"], _wheelStep, [NSTextField labelWithString:@"% per notch"]])],
        @[Label(@"Handle:"), Row(@[_handle, _shadow])],
        @[NSGridCell.emptyContentView, _login],
        @[Label(@"Screen access:"), Row(@[_permission, _permissionButton])],
        @[Label(@"Updates:"), Row(@[installed, _updStatus])],
        @[NSGridCell.emptyContentView, Row(@[_updCheck, _updDownload])],
        @[_preview, NSGridCell.emptyContentView],
        @[credits, NSGridCell.emptyContentView],
    ]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid cellForView:_preview].row.topPadding = 8;
    [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(11, 1)];
    [grid mergeCellsInHorizontalRange:NSMakeRange(0, 2) verticalRange:NSMakeRange(12, 1)];
    [grid cellForView:_preview].xPlacement = NSGridCellPlacementCenter;
    [grid cellForView:credits].xPlacement = NSGridCellPlacementFill;
    [grid cellForView:credits].row.topPadding = 6;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    for (NSInteger i = 0; i < grid.numberOfRows; i++) [grid rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = _window.contentView;
    [content addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];
}

/// Credits, as in RailSaver: separator, "MagniGlass x.y.z · created by Vangelis Makridakis & Claude · by Ax-Easy", GitHub link.
- (NSView *)creditsView {
    NSFont *font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSColor *muted = NSColor.secondaryLabelColor;
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] init];
    void (^text)(NSString *) = ^(NSString *s) {
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: muted}]];
    };
    void (^link)(NSString *, NSString *, NSColor *, BOOL) = ^(NSString *s, NSString *url, NSColor *color, BOOL bold) {
        NSMutableDictionary *a = [@{NSFontAttributeName: bold ? [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize] : font,
                                    NSLinkAttributeName: [NSURL URLWithString:url]} mutableCopy];
        if (color) a[NSForegroundColorAttributeName] = color;
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:a]];
    };
    text([NSString stringWithFormat:@"MagniGlass %@ · created by ", AppVersion()]);
    link(@"Vangelis Makridakis", @"https://www.ax-easy.com", nil, NO);
    text(@" & ");
    link(@"Claude", @"https://claude.ai", nil, NO);
    text(@" · by ");
    link(@"Ax-Easy", @"https://www.ax-easy.com", [NSColor colorWithSRGBRed:1.0 green:0.55 blue:0.10 alpha:1], YES);
    text(@"\n");
    link([NSString stringWithFormat:@"github.com/%@", kFeedRepo], [NSString stringWithFormat:@"https://github.com/%@", kFeedRepo], nil, NO);

    NSTextField *label = [NSTextField labelWithAttributedString:t];
    label.selectable = YES;              // links are clickable
    label.allowsEditingTextAttributes = YES;
    NSBox *line = [[NSBox alloc] init];
    line.boxType = NSBoxSeparator;
    NSStackView *stack = [NSStackView stackViewWithViews:@[line, label]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [line.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return stack;
}

- (void)checkUpdates {
    _updStatus.stringValue = @"Checking…";
    _updDownload.hidden = YES;
    _updCheck.enabled = NO;
    CheckForUpdate(^(NSString *latest, NSURL *download, NSString *error) {
        self->_updCheck.enabled = YES;
        self->_updURL = download ?: ReleasesPage();
        if (error || !latest) {
            self->_updStatus.stringValue = [NSString stringWithFormat:@"Could not check (%@).", error ?: @"no release"];
            self->_updDownload.title = @"Open the Releases Page";
            self->_updDownload.hidden = NO;
        } else if (VersionNewer(latest, AppVersion())) {
            self->_updStatus.stringValue = [NSString stringWithFormat:@"Version %@ is available.", latest];
            self->_updDownload.title = [NSString stringWithFormat:@"Download %@", latest];
            self->_updDownload.hidden = NO;
        } else {
            self->_updStatus.stringValue = [NSString stringWithFormat:@"Up to date (latest is %@).", latest];
        }
    });
}

- (void)downloadUpdate {
    [NSWorkspace.sharedWorkspace openURL:_updURL ?: ReleasesPage()];
}

- (void)show {
    if (!_window) [self build];
    [self load];
    [self checkUpdates];
    [NSApp activateIgnoringOtherApps:YES];
    if (!_window.visible) [_window center];
    [_window makeKeyAndOrderFront:nil];
}

- (void)load {
    NSUserDefaults *d = Defaults();
    [_shortcut showMods:(UInt32)[d integerForKey:@"hotkeyMods"] name:[d stringForKey:@"hotkeyKeyName"]];
    BOOL pct = [[d stringForKey:@"sizeUnit"] isEqualToString:@"percent"];
    [_unit selectItemAtIndex:pct ? 1 : 0];
    [self configureSize];
    _zoom.doubleValue = [d doubleForKey:@"zoom"];
    _zoomText.stringValue = [NSString stringWithFormat:@"%.1f×", _zoom.doubleValue];
    _wheel.state = [d boolForKey:@"wheelZoom"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSArray *mods = @[@"none", @"control", @"option", @"shift", @"command"];
    NSUInteger mi = [mods indexOfObject:[d stringForKey:@"wheelModifier"]];
    [_wheelMod selectItemAtIndex:mi == NSNotFound ? 0 : (NSInteger)mi];
    _wheelStep.integerValue = [d integerForKey:@"wheelStep"];
    [_handle selectItemAtIndex:[d boolForKey:@"handleLeft"] ? 1 : 0];
    _shadow.state = [d boolForKey:@"shadow"] ? NSControlStateValueOn : NSControlStateValueOff;
    if (@available(macOS 13.0, *))
        _login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self updatePermission];
    [self updateEnabled];
    [self renderPreview];
}

- (void)updatePermission {
    BOOL ok = CGPreflightScreenCaptureAccess();
    _permission.stringValue = ok ? @"Screen Recording allowed ✓" : @"Screen Recording not allowed yet";
    _permission.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
    _permissionButton.hidden = ok;
}

- (void)windowDidBecomeKey:(NSNotification *)n {
    [self updatePermission];
}

- (void)configureSize {
    BOOL pct = _unit.indexOfSelectedItem == 1;
    _sizeStepper.minValue = pct ? kMinPercent : kMinPoints;
    _sizeStepper.maxValue = pct ? kMaxPercent : kMaxPoints;
    _sizeStepper.increment = pct ? 1 : 10;
    NSInteger v = pct ? [Defaults() integerForKey:@"sizePercent"] : [Defaults() integerForKey:@"sizePoints"];
    _sizeStepper.integerValue = v;
    _size.integerValue = v;
}

- (void)unitChanged {
    BOOL pct = _unit.indexOfSelectedItem == 1;
    NSScreen *s = ScreenWithMouse(NSEvent.mouseLocation);
    double shorter = MIN(s.frame.size.width, s.frame.size.height);
    // carry the current size over to the new unit
    if (pct) {
        NSInteger p = lround([Defaults() integerForKey:@"sizePoints"] * 100.0 / shorter);
        [Defaults() setInteger:MAX(kMinPercent, MIN(kMaxPercent, p)) forKey:@"sizePercent"];
    } else {
        NSInteger p = lround([Defaults() integerForKey:@"sizePercent"] / 100.0 * shorter / 10) * 10;
        [Defaults() setInteger:MAX(kMinPoints, MIN(kMaxPoints, p)) forKey:@"sizePoints"];
    }
    [Defaults() setObject:pct ? @"percent" : @"px" forKey:@"sizeUnit"];
    [self configureSize];
    [self changed];
}

- (void)storeSize:(NSInteger)v {
    BOOL pct = _unit.indexOfSelectedItem == 1;
    v = pct ? MAX(kMinPercent, MIN(kMaxPercent, v)) : MAX(kMinPoints, MIN(kMaxPoints, v));
    _size.integerValue = v;
    _sizeStepper.integerValue = v;
    [Defaults() setInteger:v forKey:pct ? @"sizePercent" : @"sizePoints"];
    [self changed];
}

- (void)sizeEdited { [self storeSize:_size.integerValue]; }
- (void)sizeStepped { [self storeSize:_sizeStepper.integerValue]; }

- (void)zoomChanged {
    double z = round(_zoom.doubleValue * 10) / 10;
    _zoomText.stringValue = [NSString stringWithFormat:@"%.1f×", z];
    [Defaults() setDouble:z forKey:@"zoom"];
    [self changed];
}

- (void)showZoom:(double)zoom {
    if (!_window.visible) return;
    _zoom.doubleValue = zoom;
    _zoomText.stringValue = [NSString stringWithFormat:@"%.1f×", zoom];
    [self renderPreview];
}

- (void)updateEnabled {
    BOOL on = _wheel.state == NSControlStateValueOn;
    _wheelMod.enabled = on;
    _wheelStep.enabled = on;
}

- (void)changed {
    NSUserDefaults *d = Defaults();
    [d setBool:_wheel.state == NSControlStateValueOn forKey:@"wheelZoom"];
    NSArray *mods = @[@"none", @"control", @"option", @"shift", @"command"];
    [d setObject:mods[(NSUInteger)MAX(0, _wheelMod.indexOfSelectedItem)] forKey:@"wheelModifier"];
    [d setInteger:MAX(5, MIN(50, _wheelStep.integerValue)) forKey:@"wheelStep"];
    [d setBool:_handle.indexOfSelectedItem == 1 forKey:@"handleLeft"];
    [d setBool:_shadow.state == NSControlStateValueOn forKey:@"shadow"];
    [self updateEnabled];
    [self renderPreview];
    if (self.onChange) self.onChange();
}

- (void)resetShortcut {
    [_shortcut showMods:controlKey | optionKey name:@"M"];
    if (self.onShortcut) self.onShortcut(controlKey | optionKey, kVK_ANSI_M, @"M");
}

- (void)setShortcutNote:(NSString *)note error:(BOOL)error {
    _shortcutNote.stringValue = note;
    _shortcutNote.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    [_shortcut showMods:(UInt32)[Defaults() integerForKey:@"hotkeyMods"] name:[Defaults() stringForKey:@"hotkeyKeyName"]];
}

- (void)loginChanged {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        BOOL on = _login.state == NSControlStateValueOn;
        BOOL ok = on ? [SMAppService.mainAppService registerAndReturnError:&err] : [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (!ok) {
            NSLog(@"MagniGlass: login item: %@", err);
            _login.state = on ? NSControlStateValueOff : NSControlStateValueOn;
            NSAlert *a = [NSAlert alertWithError:err];
            [a beginSheetModalForWindow:_window completionHandler:nil];
        }
    }
}

- (void)openPrivacy {
    CGRequestScreenCaptureAccess();
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

- (void)renderPreview {
    CGFloat scale = _window.backingScaleFactor ?: 2.0;
    int w = (int)(440 * scale), h = (int)(260 * scale);
    int d = (int)(h * 0.52);
    CGImageRef img = CreatePreviewImage(w, h, scale, d, [Defaults() doubleForKey:@"zoom"], LensFlags());
    _preview.image = [[NSImage alloc] initWithCGImage:img size:NSMakeSize(440, 260)];
    CGImageRelease(img);
}

@end

// ---------------------------------------------------------------------------------------
#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
- (void)toggle;
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    AppDelegate *app = (__bridge AppDelegate *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{ [app toggle]; });
    return noErr;
}

static CGEventRef WheelTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userData);

@implementation AppDelegate {
    NSStatusItem *_status;
    NSMenuItem *_toggleItem;
    Magnifier *_magnifier;
    SettingsController *_settings;
    EventHotKeyRef _hotKey;
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    id _wheelMonitor;
    BOOL _suspended;
    double _wheelAccum;
    NSMenuItem *_updateItem;
    NSURL *_updateURL;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _magnifier = [[Magnifier alloc] init];

    _status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"MagniGlass"];
    icon.template = YES;
    _status.button.image = icon;
    _status.button.toolTip = @"MagniGlass";
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _toggleItem = [menu addItemWithTitle:@"Show Magnifier" action:@selector(toggle) keyEquivalent:@""];
    _toggleItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *prefs = [menu addItemWithTitle:@"Settings…" action:@selector(showSettings) keyEquivalent:@","];
    prefs.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit MagniGlass" action:@selector(terminate:) keyEquivalent:@"q"];
    _status.menu = menu;

    _settings = [[SettingsController alloc] init];
    __weak AppDelegate *weakSelf = self;
    _settings.onChange = ^{
        AppDelegate *me = weakSelf;
        if (!me) return;
        me->_magnifier.zoom = [Defaults() doubleForKey:@"zoom"];
        [me->_magnifier settingsChanged];
        [me updateWheel];
    };
    _settings.onShortcut = ^(UInt32 mods, unsigned short code, NSString *name) { [weakSelf setShortcutMods:mods code:code name:name]; };
    _settings.onRecording = ^(BOOL recording) {
        AppDelegate *me = weakSelf;
        if (me) me->_suspended = recording;
    };

    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&HotKeyHandler, 1, &spec, (__bridge void *)self, NULL);
    if (![self registerHotkey]) NSLog(@"MagniGlass: shortcut %@ unavailable", CurrentHotkeyDescription());

    if ([Defaults() boolForKey:@"firstRun"]) {
        [Defaults() setBool:NO forKey:@"firstRun"];
        [self showSettings];
        if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    }

    // Updates: look a minute after launch, then every 12 hours; a newer release shows up in the menu.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf backgroundUpdateCheck]; });
    [NSTimer scheduledTimerWithTimeInterval:12 * 3600 repeats:YES block:^(NSTimer *t) { [weakSelf backgroundUpdateCheck]; }];
}

- (void)backgroundUpdateCheck {
    CheckForUpdate(^(NSString *latest, NSURL *download, NSString *error) {
        if (!latest || !VersionNewer(latest, AppVersion())) return;
        self->_updateURL = download ?: ReleasesPage();
        NSString *title = [NSString stringWithFormat:@"Download MagniGlass %@…", latest];
        if (!self->_updateItem) {
            self->_updateItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(downloadUpdate) keyEquivalent:@""];
            self->_updateItem.target = self;
            [self->_status.menu insertItem:self->_updateItem atIndex:0];
            [self->_status.menu insertItem:NSMenuItem.separatorItem atIndex:1];
        }
        self->_updateItem.title = title;
        NSLog(@"MagniGlass: version %@ is available", latest);
    });
}

- (void)downloadUpdate {
    [NSWorkspace.sharedWorkspace openURL:_updateURL ?: ReleasesPage()];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showSettings]; // opening the app again (Finder, Spotlight) shows the settings
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self saveZoom];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    _toggleItem.title = [NSString stringWithFormat:@"%@ Magnifier   %@", _magnifier.visible ? @"Hide" : @"Show", CurrentHotkeyDescription()];
}

- (BOOL)registerHotkey {
    if (_hotKey) UnregisterEventHotKey(_hotKey);
    _hotKey = NULL;
    EventHotKeyID hid = {'MGls', 1};
    OSStatus st = RegisterEventHotKey((UInt32)[Defaults() integerForKey:@"hotkeyCode"], (UInt32)[Defaults() integerForKey:@"hotkeyMods"],
                                      hid, GetApplicationEventTarget(), 0, &_hotKey);
    return st == noErr;
}

- (void)setShortcutMods:(UInt32)mods code:(unsigned short)code name:(NSString *)name {
    NSUserDefaults *d = Defaults();
    NSInteger oldCode = [d integerForKey:@"hotkeyCode"], oldMods = [d integerForKey:@"hotkeyMods"];
    NSString *oldName = [d stringForKey:@"hotkeyKeyName"];
    [d setInteger:code forKey:@"hotkeyCode"];
    [d setInteger:mods forKey:@"hotkeyMods"];
    [d setObject:name forKey:@"hotkeyKeyName"];
    if ([self registerHotkey]) {
        [_settings setShortcutNote:[NSString stringWithFormat:@"Press %@ anywhere to show or hide the glass.", CurrentHotkeyDescription()] error:NO];
    } else {
        NSString *bad = HotkeyDescription(mods, name);
        [d setInteger:oldCode forKey:@"hotkeyCode"];
        [d setInteger:oldMods forKey:@"hotkeyMods"];
        [d setObject:oldName forKey:@"hotkeyKeyName"];
        [self registerHotkey];
        [_settings setShortcutNote:[NSString stringWithFormat:@"%@ is already used by another app: the old shortcut was kept.", bad] error:YES];
    }
}

- (void)toggle {
    if (_suspended) return;
    if (_magnifier.visible) {
        [_magnifier hide];
        [self saveZoom];
    } else {
        _magnifier.zoom = [Defaults() doubleForKey:@"zoom"];
        [_magnifier show];
    }
    [self updateWheel];
}

- (void)saveZoom {
    [Defaults() setDouble:round(_magnifier.zoom * 100) / 100 forKey:@"zoom"];
}

- (void)showSettings {
    [self saveZoom];
    [_settings show];
}

// ---- scroll wheel ----

/// While the glass is shown: an event tap that swallows the wheel (needs Accessibility
/// permission); without it, a passive monitor (zooms, but the page scrolls too).
- (void)updateWheel {
    BOOL want = _magnifier.visible && [Defaults() boolForKey:@"wheelZoom"];
    if (want) {
        if (!_tap) {
            _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                    CGEventMaskBit(kCGEventScrollWheel), WheelTap, (__bridge void *)self);
            if (_tap) {
                _tapSource = CFMachPortCreateRunLoopSource(NULL, _tap, 0);
                CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);
            } else if (![Defaults() boolForKey:@"askedAccessibility"]) {
                [Defaults() setBool:YES forKey:@"askedAccessibility"];
                NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
                AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
            }
        }
        if (_tap) CGEventTapEnable(_tap, true);
        else if (!_wheelMonitor) {
            __weak AppDelegate *weakSelf = self;
            _wheelMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^(NSEvent *e) {
                [weakSelf wheel:e];
            }];
        }
    } else {
        if (_tap) CGEventTapEnable(_tap, false);
        if (_wheelMonitor) [NSEvent removeMonitor:_wheelMonitor];
        _wheelMonitor = nil;
    }
}

- (void)reenableTap {
    if (_tap && _magnifier.visible) CGEventTapEnable(_tap, true);
}

/// Returns YES when the event was used for zooming.
- (BOOL)wheel:(NSEvent *)e {
    if (!_magnifier.visible) return NO;
    NSString *mod = [Defaults() stringForKey:@"wheelModifier"];
    NSEventModifierFlags f = e.modifierFlags;
    BOOL held = [mod isEqualToString:@"control"] ? (f & NSEventModifierFlagControl) != 0
              : [mod isEqualToString:@"option"]  ? (f & NSEventModifierFlagOption) != 0
              : [mod isEqualToString:@"shift"]   ? (f & NSEventModifierFlagShift) != 0
              : [mod isEqualToString:@"command"] ? (f & NSEventModifierFlagCommand) != 0
              : YES;
    if (!held) return NO;
    // Physical direction: pushing the wheel / fingers away zooms in, whatever "natural scrolling" says.
    double dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 30.0 : e.scrollingDeltaY;
    if (e.isDirectionInvertedFromDevice) dy = -dy;
    if ([mod isEqualToString:@"shift"] && dy == 0) { // Shift turns the wheel horizontal
        dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX / 30.0 : e.scrollingDeltaX;
        if (e.isDirectionInvertedFromDevice) dy = -dy;
    }
    if (dy == 0) return YES;
    double step = 1.0 + [Defaults() integerForKey:@"wheelStep"] / 100.0;
    _magnifier.zoom = _magnifier.zoom * pow(step, MAX(-3.0, MIN(3.0, dy)));
    [_settings showZoom:_magnifier.zoom];
    return YES;
}

@end

static CGEventRef WheelTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userData) {
    AppDelegate *app = (__bridge AppDelegate *)userData;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [app reenableTap];
        return event;
    }
    if (type != kCGEventScrollWheel) return event;
    NSEvent *e = [NSEvent eventWithCGEvent:event];
    return (e && [app wheel:e]) ? NULL : event;
}

// ---------------------------------------------------------------------------------------
#pragma mark - main

static int RenderTest(NSString *path) {
    int w = 880, h = 520;
    CGImageRef img = CreatePreviewImage(w, h, 2.0, (int)(h * 0.52), 2.5, 0);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    CGImageRelease(img);
    printf("render test %s: %s\n", ok ? "ok" : "FAILED", path.UTF8String);
    return ok ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        RegisterDefaults();
        if (argc >= 3 && strcmp(argv[1], "--render-test") == 0) return RenderTest(@(argv[2]));
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
