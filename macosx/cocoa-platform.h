/*
 * cocoa-platform.h: shared declarations for the native macOS (Cocoa)
 * front end for PuTTY.
 *
 * This front end reuses PuTTY's portable cores (terminal engine, SSH
 * stack, crypto, networking, settings, and the data-driven dialog
 * system) and replaces only the GTK-specific layer with native AppKit
 * code.
 */

#ifndef PUTTY_COCOA_PLATFORM_H
#define PUTTY_COCOA_PLATFORM_H

/* Set to 1 (e.g. -DPUTTY_MAC_DEBUG=1) to compile in the debug logging
 * (PUTTY_DEBUG env) and automated test hooks (PUTTY_TEST_* env). Off by
 * default so release builds contain none of that scaffolding. */
#ifndef PUTTY_MAC_DEBUG
#define PUTTY_MAC_DEBUG 0
#endif

#include "putty.h"
#include "terminal/terminal.h"
#include "storage.h"

/* ----------------------------------------------------------------------
 * Event-loop bridge (cocoa-eventloop.m). Implements the uxsel /
 * timing / toplevel-callback contracts on top of CFRunLoop.
 */
void osx_eventloop_setup(void);   /* call once at startup: sk_init, uxsel_init, ... */

/* ----------------------------------------------------------------------
 * Session object (cocoa-terminal.m). One per terminal window. This is
 * the macOS analogue of GTK's "struct GtkFrontend": it embeds the
 * Seat, TermWin and LogPolicy vtable headers so that a single C
 * pointer can be cast between them.
 */
typedef struct CocoaSession CocoaSession;

/* Opaque handle to the Objective-C view that actually draws. */
#ifdef __OBJC__
@class PuTTYTerminalView;
@class PuTTYWindowController;
#else
typedef struct objc_object PuTTYTerminalView;
typedef struct objc_object PuTTYWindowController;
#endif

struct CocoaSession {
    Seat seat;
    TermWin termwin;
    LogPolicy logpolicy;

    Conf *conf;
    Terminal *term;
    Backend *backend;
    LogContext *logctx;
    Ldisc *ldisc;
    struct unicode_data ucsdata;

    PuTTYTerminalView *view;          /* the drawing NSView (__bridge) */
    PuTTYWindowController *controller; /* owning window controller */

    /* Resolved display palette, as told to us by the terminal core via
     * win_palette_set(). Indexed in OSC4 space. */
    rgb palette[OSC4_NCOLOURS];

    int font_width, font_height;      /* pixel size of one character cell */
    bool exited;
    int exitcode;
};

/* Create/free a session and start its backend from a fully populated
 * Conf. On error returns NULL and writes an error string (caller frees)
 * into *error. */
CocoaSession *cocoa_session_new(Conf *conf, PuTTYTerminalView *view,
                                PuTTYWindowController *controller,
                                char **error);
void cocoa_session_free(CocoaSession *s);
#if PUTTY_MAC_DEBUG
long cocoa_test_painted_pixels(CocoaSession *s);
long cocoa_test_drawrect_pixels(CocoaSession *s);
void cocoa_test_dump_png(CocoaSession *s, const char *path);
#endif

/* Feed keyboard input (already UTF-8) from the view to the backend. */
void cocoa_session_send(CocoaSession *s, const char *buf, int len);

/* Notify the terminal core that the drawing area changed size (pixels). */
void cocoa_session_set_pixel_size(CocoaSession *s, int w, int h);
void cocoa_session_set_focus(CocoaSession *s, bool focused);

/* ----------------------------------------------------------------------
 * Config dialog (cocoa-dialog.m). Renders PuTTY's portable controlsets
 * natively. Runs modally; returns true if the user clicked Open/OK and
 * the (already-owned) conf has been updated, false on Cancel.
 */
/* Opens the config dialog as a normal (non-modal) window. `completion` is
 * called later on the main thread with ok=true if the user chose Open
 * (conf is then populated), or ok=false on Cancel. */
#ifdef __OBJC__
void cocoa_open_config_box(const char *title, Conf *conf,
                           bool midsession, int protcfginfo,
                           void (^completion)(bool ok));
#endif

/* Quit the app if no windows remain (terminal sessions or config boxes). */
void cocoa_maybe_quit(void);
int  cocoa_config_box_count(void);   /* number of open config dialogs */

/* ----------------------------------------------------------------------
 * PuTTYgen window (cocoa-puttygen.m).
 */
void cocoa_open_puttygen(void);

/* ----------------------------------------------------------------------
 * App-level helpers (cocoa-main.m).
 */
void cocoa_open_new_session(void);    /* show config box, then open a window */
void cocoa_open_session_with_conf(Conf *conf); /* open a window for conf */

#endif /* PUTTY_COCOA_PLATFORM_H */
