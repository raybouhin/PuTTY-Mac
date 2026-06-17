/*
 * cocoa-main.m: NSApplication bootstrap, menu bar, dark-mode setup,
 * window management, and the AppKit versions of the fatal/non-fatal
 * message boxes.
 */

#import <Cocoa/Cocoa.h>

#include "cocoa-platform.h"
#include "ssh.h"

/* Keep strong references to live windows. */
static NSMutableArray *g_controllers;

#if PUTTY_MAC_DEBUG
extern long g_test_rx_bytes;   /* defined in cocoa-terminal.m */
/* When running an automated test (any PUTTY_TEST_* env var), run headless:
 * no visible window, no Dock icon, no focus stealing. */
static bool g_quiet_test = false;
#else
static const bool g_quiet_test = false;
#endif

/* tiny helper so C code can show a fatal alert (defined below) */
void cs_show_fatal(const char *msg);

/* ==================================================================
 * Window controller: owns one terminal window + its session.
 */

@interface PuTTYWindowController : NSObject <NSWindowDelegate>
{
@public
    NSWindow *window;
    PuTTYTerminalView *view;
    CocoaSession *session;
}
@end

@implementation PuTTYWindowController

- (instancetype)initWithConf:(Conf *)conf
{
    self = [super init];
    if (!self) return nil;

    view = [[PuTTYTerminalView alloc] initWithSession:NULL];

    int w = conf_get_int(conf, CONF_width);
    int h = conf_get_int(conf, CONF_height);

    /* font metrics are known after the view measures its font */
    char *err = NULL;
    session = cocoa_session_new(conf, view, self, &err);

    NSSize content = NSMakeSize(w * session->font_width,
                                h * session->font_height);
    NSRect frame = NSMakeRect(0, 0, content.width, content.height);
    [view setFrameSize:content];

    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:style
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    window.title = @"PuTTY";
    window.delegate = self;
    window.contentView = view;
    window.initialFirstResponder = view;
    window.releasedWhenClosed = NO;
    [window setContentResizeIncrements:
        NSMakeSize(session->font_width, session->font_height)];
    [window center];
    if (g_quiet_test) {
        /* Show off-screen so AppKit runs real display cycles (drawRect)
         * without anything appearing on the user's screen. */
        [window setFrameOrigin:NSMakePoint(-20000, -20000)];
        [window orderFront:nil];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        BOOL ok = [window makeFirstResponder:view];
#if PUTTY_MAC_DEBUG
        if (getenv("PUTTY_DEBUG"))
            fprintf(stderr, "[putty] session window: key=%d makeFR=%d "
                    "firstResponder=%s appActive=%d\n",
                    window.isKeyWindow, ok,
                    window.firstResponder == (NSResponder *)view ?
                        "VIEW" : "other",
                    NSApp.isActive);
#else
        (void)ok;
#endif
    }

    if (err) {
        cs_show_fatal(err);
        sfree(err);
    }
    return self;
}

- (void)windowDidBecomeKey:(NSNotification *)n
{
    cocoa_session_set_focus(session, true);
    /* Ensure the terminal view is first responder so it receives keys. */
    if (view && [window firstResponder] != (NSResponder *)view)
        [window makeFirstResponder:view];
#if PUTTY_MAC_DEBUG
    if (getenv("PUTTY_DEBUG"))
        fprintf(stderr, "[putty] windowDidBecomeKey: key=%d firstResponder=%s "
                "acceptsFR=%d\n",
                window.isKeyWindow,
                window.firstResponder == (NSResponder *)view ? "VIEW" : "other",
                [view acceptsFirstResponder]);
#endif
}
- (void)windowDidResignKey:(NSNotification *)n
{ cocoa_session_set_focus(session, false); }

- (void)windowWillClose:(NSNotification *)n
{
    /* keep the controller alive long enough, then free the session */
    CocoaSession *s = session;
    session = NULL;
    if (s) cocoa_session_free(s);
    [g_controllers removeObject:self];
    cocoa_maybe_quit();
}
@end

/* Quit the application once no terminal windows and no config dialogs
 * remain open. (We don't use applicationShouldTerminateAfterLastWindow-
 * Closed because there's a brief windowless gap between closing the
 * config dialog and opening the session window.) */
void cocoa_maybe_quit(void)
{
    if (g_controllers.count == 0 && cocoa_config_box_count() == 0)
        [NSApp terminate:nil];
}

/* tiny helper so C code can show a fatal alert */
void cs_show_fatal(const char *msg)
{
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"PuTTY";
        a.informativeText = [NSString stringWithUTF8String:msg];
        a.alertStyle = NSAlertStyleCritical;
        [a runModal];
    }
}

/* ==================================================================
 * Public session-opening entry points (declared in cocoa-platform.h).
 */

void cocoa_open_session_with_conf(Conf *conf)
{
    if (!g_controllers) g_controllers = [[NSMutableArray alloc] init];
    PuTTYWindowController *c =
        [[PuTTYWindowController alloc] initWithConf:conf];
    if (c) [g_controllers addObject:c];
}

void cocoa_open_new_session(void)
{
    Conf *conf = conf_new();
    do_defaults(NULL, conf);
    cocoa_open_config_box("PuTTY Configuration", conf, false, 0, ^(bool ok) {
        if (ok)
            cocoa_open_session_with_conf(conf);   /* conf ownership -> session */
        else
            conf_free(conf);
    });
}

/* ==================================================================
 * Application delegate + menus.
 */

@interface PuTTYAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation PuTTYAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    if (!g_quiet_test)
        [NSApp activateIgnoringOtherApps:YES];

#if PUTTY_MAC_DEBUG
    /* Automated test hook: PUTTY_TEST_RAW=host:port connects via the raw
     * backend (no dialog) and reports bytes received, then exits. Used to
     * verify the event-loop/network/seat/terminal data path. */
    const char *testraw = getenv("PUTTY_TEST_RAW");
    const char *testssh = getenv("PUTTY_TEST_SSH");
    if (testraw || testssh) {
        char *spec = dupstr(testraw ? testraw : testssh);
        char *colon = strrchr(spec, ':');
        int port = testssh ? 22 : 23;
        if (colon) { *colon = '\0'; port = atoi(colon + 1); }
        Conf *conf = conf_new();
        do_defaults(NULL, conf);
        conf_set_int(conf, CONF_protocol, testssh ? PROT_SSH : PROT_RAW);
        conf_set_str(conf, CONF_host, spec);
        conf_set_int(conf, CONF_port, port);
        if (testssh && getenv("PUTTY_TEST_USER"))
            conf_set_str(conf, CONF_username, getenv("PUTTY_TEST_USER"));
        sfree(spec);
        cocoa_open_session_with_conf(conf);
        const char *totype = getenv("PUTTY_TEST_TYPE");
        if (totype) {
            NSString *t = [NSString stringWithUTF8String:totype];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                PuTTYWindowController *cc = g_controllers.firstObject;
                if (!cc) return;
                /* Inject real keyDown: events into the view, exercising the
                 * exact path a physical keypress takes. */
                for (NSUInteger i = 0; i < t.length; i++) {
                    NSString *ch = [t substringWithRange:NSMakeRange(i, 1)];
                    NSEvent *ev = [NSEvent keyEventWithType:NSEventTypeKeyDown
                        location:NSZeroPoint modifierFlags:0 timestamp:0
                        windowNumber:cc->window.windowNumber context:nil
                        characters:ch charactersIgnoringModifiers:ch
                        isARepeat:NO keyCode:0];
                    [cc->view keyDown:ev];
                }
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            PuTTYWindowController *c = g_controllers.firstObject;
            const char *dump = getenv("PUTTY_TEST_DUMP");
            if (c && dump) cocoa_test_dump_png(c->session, dump);
            long px = c ? cocoa_test_painted_pixels(c->session) : -99;
            long dr = c ? cocoa_test_drawrect_pixels(c->session) : -99;
            extern long g_test_draw_calls, g_test_drawrect_calls;
            fprintf(stderr, "TEST_RX_BYTES=%ld DRAW_CALLS=%ld "
                    "PAINTED_PIXELS=%ld DRAWRECT_PIXELS=%ld "
                    "NATURAL_DRAWRECT_CALLS=%ld\n",
                    g_test_rx_bytes, g_test_draw_calls, px, dr,
                    g_test_drawrect_calls);
            exit(g_test_rx_bytes > 0 && px > 0 ? 0 : 2);
        });
        return;
    }
#endif /* PUTTY_MAC_DEBUG */

    cocoa_open_new_session();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a
{ return NO; }

- (void)newSession:(id)sender { cocoa_open_new_session(); }

/* Right-click (Dock) menu: offer "New Session" like VS Code's New Window. */
- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
    NSMenu *m = [[NSMenu alloc] init];
    [[m addItemWithTitle:@"New Session…"
                  action:@selector(newSession:)
           keyEquivalent:@""] setTarget:self];
    [[m addItemWithTitle:@"PuTTYgen (Key Generator)…"
                  action:@selector(openPuTTYgen:)
           keyEquivalent:@""] setTarget:self];
    return m;
}
- (void)openPuTTYgen:(id)sender
{
    /* PuTTYgen is a separate executable (its key-generation math must not
     * share a binary with the constant-time SSH client). Launch the helper
     * that ships alongside us in the bundle. */
    NSString *dir = [[NSBundle mainBundle].executablePath
                     stringByDeletingLastPathComponent];
    NSString *gen = [dir stringByAppendingPathComponent:@"puttygen"];
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:gen];
    @try { [t launch]; }
    @catch (NSException *e) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"PuTTYgen";
        a.informativeText = @"Could not launch the PuTTYgen helper.";
        [a runModal];
    }
}

@end

static NSMenu *build_menu(void)
{
    NSMenu *mainMenu = [[NSMenu alloc] init];

    /* Application menu */
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About PuTTY"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide PuTTY"
                       action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit PuTTY"
                       action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    /* File menu */
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [[fileMenu addItemWithTitle:@"New Session…"
                         action:@selector(newSession:)
                  keyEquivalent:@"n"] setTarget:NSApp.delegate];
    [[fileMenu addItemWithTitle:@"PuTTYgen (Key Generator)…"
                         action:@selector(openPuTTYgen:)
                  keyEquivalent:@""] setTarget:NSApp.delegate];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:)
                 keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;

    /* Edit menu (copy/paste) */
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:)
                 keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:)
                 keyEquivalent:@"v"];
    editItem.submenu = editMenu;

    return mainMenu;
}

/* ==================================================================
 * AppKit overrides of the message-box glue (strong symbols override
 * the weak stderr versions in cocoa-glue.c).
 */

void nonfatal(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap); va_end(ap);
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"PuTTY Error";
        a.informativeText = [NSString stringWithUTF8String:msg];
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
    }
    sfree(msg);
}

void modalfatalbox(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap); va_end(ap);
    cs_show_fatal(msg);
    sfree(msg);
    cleanup_exit(1);
}

/* ==================================================================
 * main()
 */

int main(int argc, char **argv)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
#if PUTTY_MAC_DEBUG
        if (getenv("PUTTY_TEST_RAW") || getenv("PUTTY_TEST_CONFIG") ||
            getenv("PUTTY_TEST_PAINT") || getenv("PUTTY_TEST_SSH") ||
            getenv("PUTTY_TEST_DBLCLICK"))
            g_quiet_test = true;
#endif
        NSApp.activationPolicy = g_quiet_test ?
            NSApplicationActivationPolicyProhibited :
            NSApplicationActivationPolicyRegular;

        /* Follow the system appearance (light or dark) automatically.
         * Leaving the app appearance unset makes AppKit track the user's
         * current macOS theme and switch live if they change it. The
         * terminal itself keeps PuTTY's own colour palette regardless. */
        NSApp.appearance = nil;

        /* PuTTY portable init. */
        enable_dit();
        settings_set_default_protocol(be_default_protocol);
        {
            const struct BackendVtable *vt =
                backend_vt_from_proto(be_default_protocol);
            settings_set_default_port(vt ? vt->default_port : 22);
        }
        osx_eventloop_setup();

        /* Set the delegate BEFORE building the menu, so the menu items
         * that target the delegate (New Session, PuTTYgen) bind correctly. */
        PuTTYAppDelegate *del = [[PuTTYAppDelegate alloc] init];
        NSApp.delegate = del;
        NSApp.mainMenu = build_menu();

        [NSApp run];
    }
    return 0;
}
