/*
 * cocoa-terminal.m: the native macOS terminal window.
 *
 * This file is the macOS analogue of unix/window.c. It provides:
 *
 *   - PuTTYTerminalView: an NSView that renders PuTTY's terminal grid
 *     using Core Text into an offscreen bitmap "backing store" (exactly
 *     the model GTK uses with a cairo surface), then blits it on draw.
 *
 *   - the TermWin vtable, through which terminal.c performs all drawing;
 *   - the Seat vtable, through which the SSH backend talks to the user;
 *   - the LogPolicy vtable;
 *   - session creation/teardown wiring all of the above to the backend.
 */

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

#include "cocoa-platform.h"
#include "ssh.h"

/* ------------------------------------------------------------------
 * Helpers to recover the CocoaSession from a vtable pointer. Because
 * Seat/TermWin/LogPolicy are the first members' siblings inside
 * CocoaSession, we use container_of-style offset maths.
 */
static inline CocoaSession *session_from_seat(Seat *seat)
{ return container_of(seat, CocoaSession, seat); }
static inline CocoaSession *session_from_termwin(TermWin *tw)
{ return container_of(tw, CocoaSession, termwin); }
static inline CocoaSession *session_from_logpolicy(LogPolicy *lp)
{ return container_of(lp, CocoaSession, logpolicy); }

long g_test_draw_calls = 0;   /* instrumentation for automated tests */

/* Lightweight debug logging to stderr, enabled with PUTTY_DEBUG=1.
 * Compiled out entirely unless PUTTY_MAC_DEBUG is set. */
#if PUTTY_MAC_DEBUG
static bool dbg_on(void)
{ static int v = -1; if (v < 0) v = getenv("PUTTY_DEBUG") ? 1 : 0; return v; }
#define DBG(...) do { if (dbg_on()) { \
    fprintf(stderr, "[putty] " __VA_ARGS__); fputc('\n', stderr); \
    fflush(stderr); } } while (0)
#else
#define DBG(...) ((void)0)
#endif

/*
 * Deliver keyboard input to the terminal. "dedicated" marks input that
 * comes from a real dedicated key (Backspace, Return, arrows, function
 * keys, ...) as opposed to ordinary typed text. PuTTY's line editor (used
 * for the in-terminal "login as:" / password prompts) only treats
 * Backspace and Return as editing keys when they arrive dedicated;
 * otherwise it echoes them literally (e.g. Backspace shows up as ^?).
 * The signal for "dedicated" is a negative (null-terminated) length, so
 * dedicated sequences must not contain a NUL byte.
 */
static void send_keys(CocoaSession *s, const char *buf, int len,
                      bool dedicated)
{
    if (!s || !s->term) return;
    if (dedicated) {
        char tmp[80];
        if (len > (int)sizeof(tmp) - 1) len = sizeof(tmp) - 1;
        memcpy(tmp, buf, len);
        tmp[len] = '\0';
        term_keyinput(s->term, -1, tmp, -1);   /* negative len -> DEDICATED */
    } else {
        term_keyinput(s->term, -1, buf, len);
    }
    /* Drain the repaint callback so the echo appears immediately. */
    while (run_toplevel_callbacks())
        ;
}

/* ==================================================================
 * The drawing view.
 */

@interface PuTTYTerminalView : NSView <NSTextInputClient>
{
@public
    CocoaSession *sess;
    CGContextRef backing;        /* offscreen bitmap, top row = terminal row 0 */
    int backing_w, backing_h;    /* backing store size in points */
    CGFloat scale;               /* backing scale factor (retina) */

    CTFontRef font_regular;
    CTFontRef font_bold;
    CGFloat ascent, descent;
    int cols, rows;
    bool draw_ctx_active;
}
- (void)recreateBackingForCols:(int)c rows:(int)r;
- (void)remeasureFont;
@end

@implementation PuTTYTerminalView

- (instancetype)initWithSession:(CocoaSession *)s
{
    self = [super initWithFrame:NSMakeRect(0, 0, 640, 384)];
    if (self) {
        sess = s;
        scale = 1.0;
        [self remeasureFont];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }            /* top-left origin, y downwards */
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return NO; }

- (void)remeasureFont
{
    if (font_regular) CFRelease(font_regular);
    if (font_bold) CFRelease(font_bold);

    const char *fontname = "Menlo";
    CGFloat size = 12.0;
    if (sess && sess->conf) {
        FontSpec *fs = conf_get_fontspec(sess->conf, CONF_font);
        if (fs && fs->name && *fs->name) {
            /* FontSpec name is like "Menlo 12"; split off trailing size. */
            char *namecopy = dupstr(fs->name);
            char *sp = strrchr(namecopy, ' ');
            if (sp) {
                int n = atoi(sp + 1);
                if (n > 0) { size = n; *sp = '\0'; }
            }
            static char buf[256];
            strncpy(buf, namecopy, sizeof(buf) - 1);
            fontname = buf;
            sfree(namecopy);
        }
    }

    CFStringRef cfname = CFStringCreateWithCString(
        NULL, fontname, kCFStringEncodingUTF8);
    font_regular = CTFontCreateWithName(cfname, size, NULL);
    CFRelease(cfname);
    if (!font_regular)
        font_regular = CTFontCreateWithName(CFSTR("Menlo"), size, NULL);
    font_bold = CTFontCreateCopyWithSymbolicTraits(
        font_regular, size, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
    if (!font_bold) { font_bold = font_regular; CFRetain(font_bold); }

    ascent = CTFontGetAscent(font_regular);
    descent = CTFontGetDescent(font_regular);
    CGFloat leading = CTFontGetLeading(font_regular);

    /* monospace cell width: advance of 'M' */
    UniChar m = 'M';
    CGGlyph g = 0;
    CTFontGetGlyphsForCharacters(font_regular, &m, &g, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(font_regular, kCTFontOrientationHorizontal,
                               &g, &adv, 1);
    int fw = (int)ceil(adv.width);
    int fh = (int)ceil(ascent + descent + leading);
    if (fw < 1) fw = 7;
    if (fh < 1) fh = 14;
    if (sess) { sess->font_width = fw; sess->font_height = fh; }
}

- (void)recreateBackingForCols:(int)c rows:(int)r
{
    cols = c; rows = r;
    int fw = sess->font_width, fh = sess->font_height;
    int w = c * fw, h = r * fh;
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    if (backing) { CGContextRelease(backing); backing = NULL; }
    backing_w = w; backing_h = h;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    backing = CGBitmapContextCreate(
        NULL, (size_t)(w * scale), (size_t)(h * scale), 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    DBG("recreateBacking cols=%d rows=%d fw=%d fh=%d scale=%g w=%d h=%d "
        "backing=%p", c, r, fw, fh, scale, w, h, (void*)backing);
    if (!backing) return;
    CGContextScaleCTM(backing, scale, scale);

    /* clear to default background (palette index 258) */
    rgb bg = sess->palette[258];
    CGContextSetRGBFillColor(backing, bg.r/255.0, bg.g/255.0, bg.b/255.0, 1);
    CGContextFillRect(backing, CGRectMake(0, 0, w, h));

    [self setNeedsDisplay:YES];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    CGFloat ns = self.window ? self.window.backingScaleFactor : 1.0;
    if (ns != scale && ns > 0) {
        scale = ns;
        if (sess && sess->term)
            [self recreateBackingForCols:cols rows:rows];
    }
}

long g_test_drawrect_calls = 0;

- (void)drawRect:(NSRect)dirtyRect
{
    g_test_drawrect_calls++;
    CGContextRef c = [[NSGraphicsContext currentContext] CGContext];
    if (!backing) {
        CGContextSetRGBFillColor(c, 0, 0, 0, 1);
        CGContextFillRect(c, dirtyRect);
        return;
    }
    CGImageRef img = CGBitmapContextCreateImage(backing);
    /* Blit the backing upright, anchored at the TOP-left of the view.
     * (Anchoring to the view height instead of the image height would push
     * the terminal down whenever the window is a few pixels taller than an
     * exact character-cell multiple, leaving a gap at the top.) */
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, backing_h);
    CGContextScaleCTM(c, 1, -1);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, backing_w, backing_h), img);
    CGContextRestoreGState(c);
    CGImageRelease(img);
}

/* ---- size negotiation ---- */

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    if (!sess || !sess->term) return;
    int fw = sess->font_width, fh = sess->font_height;
    int newcols = (int)(newSize.width / fw);
    int newrows = (int)(newSize.height / fh);
    if (newcols < 1) newcols = 1;
    if (newrows < 1) newrows = 1;
    if (newcols != cols || newrows != rows) {
        [self recreateBackingForCols:newcols rows:newrows];
        term_size(sess->term, newrows, newcols,
                  conf_get_int(sess->conf, CONF_savelines));
        if (sess->backend)
            backend_size(sess->backend, newcols, newrows);
    }
}

/* ---- focus ---- */
- (BOOL)becomeFirstResponder
{ if (sess && sess->term) term_set_focus(sess->term, true);
  [self setNeedsDisplay:YES]; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder
{ if (sess && sess->term) term_set_focus(sess->term, false);
  [self setNeedsDisplay:YES]; return [super resignFirstResponder]; }

/* ---- mouse ---- */

- (void)mouseEventRaw:(NSEvent *)e raw:(Mouse_Button)braw
               cooked:(Mouse_Button)bcooked action:(Mouse_Action)a
{
    if (!sess || !sess->term) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int col = (int)(p.x / sess->font_width);
    int row = (int)(p.y / sess->font_height);
    if (col < 0) col = 0; if (col >= cols) col = cols - 1;
    if (row < 0) row = 0; if (row >= rows) row = rows - 1;
    NSUInteger m = e.modifierFlags;
    DBG("mouse raw=%d cooked=%d action=%d at %d,%d", braw, bcooked, a, col, row);
    /* term_mouse dispatches selection/extend/paste on the *cooked* button. */
    term_mouse(sess->term, braw, bcooked, a, col, row,
               (m & NSEventModifierFlagShift) != 0,
               (m & NSEventModifierFlagControl) != 0,
               (m & NSEventModifierFlagOption) != 0);
}

/* Map the right and middle physical buttons to PuTTY's logical actions.
 * Right-click pastes (the macOS convention), except in explicit xterm
 * mode where it extends the selection like X11/xterm. Middle-click pastes
 * except in Windows mode where it extends. Left is always Select; hold
 * Shift with the left button to extend a selection. */
- (Mouse_Button)rightButtonAction
{
    return conf_get_int(sess->conf, CONF_mouse_is_xterm) == MOUSE_XTERM ?
        MBT_EXTEND : MBT_PASTE;
}
- (Mouse_Button)middleButtonAction
{
    return conf_get_int(sess->conf, CONF_mouse_is_xterm) == MOUSE_WINDOWS ?
        MBT_EXTEND : MBT_PASTE;
}

- (void)mouseDown:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_LEFT cooked:MBT_SELECT
               action:(e.clickCount >= 3 ? MA_3CLK :
                       e.clickCount == 2 ? MA_2CLK : MA_CLICK)]; }
- (void)mouseDragged:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_LEFT cooked:MBT_SELECT action:MA_DRAG]; }
- (void)mouseUp:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_LEFT cooked:MBT_SELECT action:MA_RELEASE]; }
- (void)rightMouseDown:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_RIGHT cooked:[self rightButtonAction]
              action:MA_CLICK]; }
- (void)rightMouseUp:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_RIGHT cooked:[self rightButtonAction]
              action:MA_RELEASE]; }
- (void)otherMouseDown:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_MIDDLE cooked:[self middleButtonAction]
              action:MA_CLICK]; }
- (void)otherMouseUp:(NSEvent *)e
{ [self mouseEventRaw:e raw:MBT_MIDDLE cooked:[self middleButtonAction]
              action:MA_RELEASE]; }

/* ---- keyboard ---- */

- (void)keyDown:(NSEvent *)e
{
    DBG("keyDown fired: keyCode=%d chars='%s' sess=%p term=%p",
        (int)e.keyCode,
        e.charactersIgnoringModifiers.UTF8String ?: "",
        (void*)sess, (void*)(sess ? sess->term : NULL));
    if (!sess || !sess->term) return;
    Terminal *term = sess->term;
    term_seen_key_event(term);

    NSString *chars = e.charactersIgnoringModifiers;
    NSUInteger mods = e.modifierFlags;
    unichar uc = chars.length ? [chars characterAtIndex:0] : 0;

    bool shift = (mods & NSEventModifierFlagShift) != 0;
    bool ctrl  = (mods & NSEventModifierFlagControl) != 0;
    bool alt   = (mods & NSEventModifierFlagOption) != 0;   /* Option = Meta */
    bool keypad = (mods & NSEventModifierFlagNumericPad) != 0;

    char buf[64];
    int n = -1;            /* >=0 once a formatter has produced a sequence */
    bool consumed_alt = false;
    int xkey = 0;
    SmallKeypadKey skk = (SmallKeypadKey)-1;

    /*
     * Cursor / function / editing keys, formatted by PuTTY's own portable
     * routines so we honour every mode (VT52, application cursor/keypad,
     * the funky-type variants, and xterm modifier bitmaps) exactly like
     * the other PuTTY front ends.
     */
    if (uc >= NSF1FunctionKey && uc <= NSF35FunctionKey) {
        int fk = (int)(uc - NSF1FunctionKey) + 1;
        n = format_function_key(buf, term, fk, shift, ctrl, alt, &consumed_alt);
    } else {
        switch (uc) {
          case NSUpArrowFunctionKey:    xkey = 'A'; break;
          case NSDownArrowFunctionKey:  xkey = 'B'; break;
          case NSRightArrowFunctionKey: xkey = 'C'; break;
          case NSLeftArrowFunctionKey:  xkey = 'D'; break;
          case NSHomeFunctionKey:       skk = SKK_HOME; break;
          case NSEndFunctionKey:        skk = SKK_END; break;
          case NSInsertFunctionKey:     skk = SKK_INSERT; break;
          case NSDeleteFunctionKey:     skk = SKK_DELETE; break;  /* fwd del */
          case NSPageUpFunctionKey:     skk = SKK_PGUP; break;
          case NSPageDownFunctionKey:   skk = SKK_PGDN; break;
        }
        if (xkey) {
            n = format_arrow_key(buf, term, xkey, shift, ctrl, alt,
                                 &consumed_alt);
        } else if (skk != (SmallKeypadKey)-1) {
            if (ctrl) return;   /* these keys produce nothing with Ctrl */
            n = format_small_keypad_key(buf, term, skk, shift, ctrl, alt,
                                        &consumed_alt);
        } else if (keypad && uc >= 0x20 && uc < 0x7f &&
                   (strchr("0123456789.+-*/", (char)uc) != NULL)) {
            /* Numeric keypad in application/Nethack mode. Returns 0 when
             * the key should just type its literal character. */
            n = format_numeric_keypad_key(buf, term, (char)uc, shift, ctrl);
            if (n == 0) n = -1;   /* fall through to literal handling */
        }
    }

    if (n >= 0) {
        /*
         * At an in-terminal username/password prompt the input goes
         * through PuTTY's simple line editor rather than to a remote
         * shell. It can't use raw cursor escape sequences (the leading
         * Esc would erase the whole line and the rest would echo as
         * "[C"/"[D" garbage), so instead we translate the editing keys
         * into the dedicated control codes the line editor understands,
         * giving real in-line editing at the prompt. Keys it has no use
         * for (Up/Down history, function keys, PageUp/Down) are swallowed.
         * At a normal shell userpass_state is NULL and the escape
         * sequence is sent to the remote as usual.
         */
        if (term->userpass_state) {
            char c = 0;
            if (xkey == 'D')            c = 'B' & 0x1f;  /* Left  -> ^B */
            else if (xkey == 'C')       c = 'F' & 0x1f;  /* Right -> ^F */
            else if (skk == SKK_HOME)   c = 'A' & 0x1f;  /* Home  -> ^A */
            else if (skk == SKK_END)    c = 'E' & 0x1f;  /* End   -> ^E */
            else if (skk == SKK_DELETE) c = 'D' & 0x1f;  /* Del   -> ^D */
            if (c)
                send_keys(sess, &c, 1, true);            /* dedicated */
            return;
        }
        if (alt && !consumed_alt) {     /* Meta prefix: Esc + sequence */
            char out[66]; out[0] = 0x1b; memcpy(out + 1, buf, n);
            send_keys(sess, out, n + 1, true);
        } else {
            send_keys(sess, buf, n, true);
        }
        return;
    }

    /* Backspace: we decide, not the OS. Shift inverts the configured sense.
     * Sent dedicated so the in-terminal prompts treat it as the erase key
     * instead of echoing ^?. */
    if (uc == 0x7f || uc == NSBackspaceCharacter || uc == 8) {
        bool del = conf_get_bool(sess->conf, CONF_bksp_is_delete);
        if (shift) del = !del;
        char b = del ? 0x7f : 0x08;
        send_keys(sess, &b, 1, true);
        return;
    }

    /* Shift-Tab is ESC [ Z (suppressed at a userpass prompt, as above). */
    if (uc == '\t' && shift) {
        if (!term->userpass_state)
            send_keys(sess, "\x1b[Z", 3, true);
        return;
    }

    /* Return / Enter -> CR (the terminal/host handles CR to CRLF). */
    if (uc == '\r' || uc == NSEnterCharacter || uc == NSCarriageReturnCharacter) {
        send_keys(sess, "\r", 1, true);
        return;
    }

    /* Escape */
    if (uc == 0x1b) { send_keys(sess, "\x1b", 1, true); return; }

    /*
     * Control combinations on ordinary keys, following PuTTY's X11 policy:
     *   ^2 ^Space ^@  -> NUL
     *   ^3..^7        -> 0x1B..0x1F
     *   ^8            -> DEL (0x7F)
     *   ^/            -> 0x1F      ^`  -> 0x1C
     *   0x40..0x7E    -> masked with 0x1F
     */
    if (ctrl && uc >= 0x20 && uc < 0x80) {
        int c = uc;
        if (c >= '3' && c <= '7') c += 0x1B - '3';
        else if (c == '2' || c == ' ' || c == '@') c = 0;
        else if (c == '8') c = 0x7f;
        else if (c == '/') c = 0x1f;
        else if (c == '`') c = 0x1c;
        else if (c >= 0x40 && c < 0x7f) c &= 0x1f;
        else c = -1;
        if (c >= 0) {
            char b = (char)c;
            if (alt) { char out[2] = {0x1b, b}; cocoa_session_send(sess, out, 2); }
            else cocoa_session_send(sess, &b, 1);
            return;
        }
    }

    /* Ordinary text, with Option/Meta sending an Esc prefix. */
    NSString *text = e.characters;
    if (text.length) {
        const char *u8 = text.UTF8String;
        if (u8) {
            if (alt) { char esc = 0x1b; cocoa_session_send(sess, &esc, 1); }
            cocoa_session_send(sess, u8, (int)strlen(u8));
        }
    }
}

/* Minimal NSTextInputClient so the system doesn't beep; we handle keys
 * directly in keyDown:, so most of these are stubs. */
- (void)insertText:(id)s replacementRange:(NSRange)r {}
- (void)doCommandBySelector:(SEL)sel {}
- (void)setMarkedText:(id)s selectedRange:(NSRange)a replacementRange:(NSRange)b {}
- (void)unmarkText {}
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { return NO; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r
                                                actualRange:(NSRangePointer)a
{ return nil; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)a
{ return NSZeroRect; }
- (NSUInteger)characterIndexForPoint:(NSPoint)p { return NSNotFound; }

@end

/* ==================================================================
 * Colour resolution helpers.
 */

static void resolve_colours(CocoaSession *s, unsigned long attr, truecolour tc,
                            rgb *fg_out, rgb *bg_out)
{
    unsigned fgi = (attr & ATTR_FGMASK) >> ATTR_FGSHIFT;
    unsigned bgi = (attr & ATTR_BGMASK) >> ATTR_BGSHIFT;

    rgb fg = (fgi < OSC4_NCOLOURS) ? s->palette[fgi] : s->palette[256];
    rgb bg = (bgi < OSC4_NCOLOURS) ? s->palette[bgi] : s->palette[258];

    if (tc.fg.enabled) { fg.r = tc.fg.r; fg.g = tc.fg.g; fg.b = tc.fg.b; }
    if (tc.bg.enabled) { bg.r = tc.bg.r; bg.g = tc.bg.g; bg.b = tc.bg.b; }

    if (attr & ATTR_REVERSE) { rgb t = fg; fg = bg; bg = t; }
    if (attr & ATTR_DIM) { fg.r /= 2; fg.g /= 2; fg.b /= 2; }

    *fg_out = fg; *bg_out = bg;
}

/* Build a sanitized CFString from PuTTY's wchar_t (UTF-32) run. */
static CFStringRef make_cfstring(const wchar_t *text, int len)
{
    uint32_t *buf = snewn(len > 0 ? len : 1, uint32_t);
    int n = 0;
    for (int i = 0; i < len; i++) {
        uint32_t ch = (uint32_t)text[i];
        if (ch >= 0xD800 && ch <= 0xDFFF) ch = ' ';   /* incl. UCSWIDE */
        if (ch == 0) ch = ' ';
        buf[n++] = ch;
    }
    CFStringRef s = CFStringCreateWithBytes(
        NULL, (const UInt8 *)buf, n * sizeof(uint32_t),
        kCFStringEncodingUTF32LE, false);
    sfree(buf);
    if (!s) s = CFSTR("");
    return s;
}

static void draw_run(CocoaSession *s, int x, int y, wchar_t *text, int len,
                     unsigned long attr, int lattr, truecolour tc,
                     bool is_cursor)
{
    PuTTYTerminalView *v = s->view;
    CGContextRef c = v->backing;
    if (!c) return;
    g_test_draw_calls++;
    int fw = s->font_width, fh = s->font_height;

    rgb fg, bg;
    resolve_colours(s, attr, tc, &fg, &bg);

    if (is_cursor && (attr & ATTR_ACTCURS)) {
        /* active block cursor: paint with cursor colours */
        rgb t = fg; fg = s->palette[258 /*bg*/]; bg = s->palette[261 /*curs*/];
        (void)t;
        fg = s->palette[258]; bg = s->palette[261];
    }

    int px = x * fw;
    int cell_bottom_cg = v->backing_h - (y + 1) * fh;
    CGRect cell = CGRectMake(px, cell_bottom_cg, len * fw, fh);

    /* background */
    CGContextSetRGBFillColor(c, bg.r/255.0, bg.g/255.0, bg.b/255.0, 1);
    CGContextFillRect(c, cell);

    /*
     * Text. We must place each character on the fixed cell grid (one cell
     * = font_width points). Drawing a whole run as a single Core Text line
     * would let glyphs advance by the font's *natural* width (e.g. ~7.2px
     * for Menlo 12) instead of our integer cell width (8px), so text would
     * drift left of the grid across a line and desync from the cursor and
     * from the server's idea of column positions. So we draw each cell's
     * glyph individually at its exact grid x.
     */
    CTFontRef font = (attr & ATTR_BOLD) ? v->font_bold : v->font_regular;
    CGColorRef col = CGColorCreateGenericRGB(
        fg.r/255.0, fg.g/255.0, fg.b/255.0, 1);
    CFStringRef keys[] = { kCTFontAttributeName,
                           kCTForegroundColorAttributeName };
    CFTypeRef vals[] = { font, col };
    CFDictionaryRef attrs = CFDictionaryCreate(
        NULL, (const void **)keys, (const void **)vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGFloat baseline = cell_bottom_cg + v->descent;

    int celloff = 0;
    for (int i = 0; i < len; i++) {
        uint32_t ch = (uint32_t)text[i];
        if (ch == 0xDFFF) { celloff++; continue; }  /* RHS of wide char */
        if ((ch >= 0xD800 && ch <= 0xDFFF) || ch == 0) ch = ' ';
        if (ch == ' ') { celloff++; continue; }     /* nothing to draw */

        CFStringRef cs = CFStringCreateWithBytes(
            NULL, (const UInt8 *)&ch, sizeof(ch),
            kCFStringEncodingUTF32LE, false);
        if (cs) {
            CFAttributedStringRef as = CFAttributedStringCreate(NULL, cs, attrs);
            CTLineRef line = CTLineCreateWithAttributedString(as);
            CGContextSetTextPosition(c, px + celloff * fw, baseline);
            CTLineDraw(line, c);
            CFRelease(line); CFRelease(as); CFRelease(cs);
        }
        celloff++;
    }

    if (attr & ATTR_UNDER) {
        CGContextSetRGBStrokeColor(c, fg.r/255.0, fg.g/255.0, fg.b/255.0, 1);
        CGContextSetLineWidth(c, 1.0);
        CGContextMoveToPoint(c, px, cell_bottom_cg + 1.5);
        CGContextAddLineToPoint(c, px + len*fw, cell_bottom_cg + 1.5);
        CGContextStrokePath(c);
    }
    CFRelease(attrs); CGColorRelease(col);

    /* non-block cursors */
    if (is_cursor && (attr & (ATTR_PASCURS|ATTR_ACTCURS))) {
        int ctype = conf_get_int(s->conf, CONF_cursor_type);
        rgb cc = s->palette[261];
        CGContextSetRGBStrokeColor(c, cc.r/255.0, cc.g/255.0, cc.b/255.0, 1);
        CGContextSetRGBFillColor(c, cc.r/255.0, cc.g/255.0, cc.b/255.0, 1);
        if (ctype == CURSOR_UNDERLINE) {
            CGContextFillRect(c, CGRectMake(px, cell_bottom_cg, fw, 2));
        } else if (ctype == CURSOR_VERTICAL_LINE) {
            CGContextFillRect(c, CGRectMake(px, cell_bottom_cg, 1, fh));
        } else if (attr & ATTR_PASCURS) {
            CGContextSetLineWidth(c, 1.0);
            CGContextStrokeRect(c, CGRectMake(px+0.5, cell_bottom_cg+0.5,
                                              fw*len-1, fh-1));
        }
    }
}

/* ==================================================================
 * TermWin vtable.
 */

static bool cw_setup_draw_ctx(TermWin *tw)
{
    CocoaSession *s = session_from_termwin(tw);
    bool ok = s->view && s->view->backing != NULL;
    DBG("setup_draw_ctx -> %d", ok);
    return ok;
}
static void cw_free_draw_ctx(TermWin *tw)
{
    CocoaSession *s = session_from_termwin(tw);
    DBG("free_draw_ctx (draws so far=%ld) setNeedsDisplay", g_test_draw_calls);
    [s->view setNeedsDisplay:YES];
}
static void cw_draw_text(TermWin *tw, int x, int y, wchar_t *text, int len,
                         unsigned long attr, int lattr, truecolour tc)
{ draw_run(session_from_termwin(tw), x, y, text, len, attr, lattr, tc, false); }
static void cw_draw_cursor(TermWin *tw, int x, int y, wchar_t *text, int len,
                           unsigned long attr, int lattr, truecolour tc)
{ draw_run(session_from_termwin(tw), x, y, text, len, attr, lattr, tc, true); }
static void cw_draw_trust_sigil(TermWin *tw, int x, int y) {}
static int cw_char_width(TermWin *tw, int uc) { return 1; }
static void cw_set_cursor_pos(TermWin *tw, int x, int y) {}
static void cw_set_raw_mouse_mode(TermWin *tw, bool e) {}
static void cw_set_raw_mouse_mode_pointer(TermWin *tw, bool e) {}
static void cw_set_scrollbar(TermWin *tw, int total, int start, int page) {}
static void cw_bell(TermWin *tw, int mode)
{ if (mode != BELL_DISABLED) NSBeep(); }

static void cw_clip_write(TermWin *tw, int clipboard, wchar_t *text,
                          int *attrs, truecolour *colours, int len,
                          bool deselect)
{
    if (clipboard != CLIP_LOCAL) {
        /* Selection -> system pasteboard. */
        uint32_t *buf = snewn(len > 0 ? len : 1, uint32_t);
        int n = 0;
        for (int i = 0; i < len; i++) {
            uint32_t ch = (uint32_t)text[i];
            if (ch >= 0xD800 && ch <= 0xDFFF) continue;
            buf[n++] = ch;
        }
        CFStringRef s = CFStringCreateWithBytes(
            NULL, (const UInt8 *)buf, n*sizeof(uint32_t),
            kCFStringEncodingUTF32LE, false);
        sfree(buf);
        if (s) {
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:(__bridge NSString *)s forType:NSPasteboardTypeString];
            CFRelease(s);
        }
    }
}
static void cw_clip_request_paste(TermWin *tw, int clipboard)
{
    CocoaSession *s = session_from_termwin(tw);
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    DBG("clip_request_paste clipboard=%d str=%s", clipboard,
        str ? str.UTF8String : "(nil)");
    if (str) {
        NSUInteger len = str.length;
        wchar_t *wbuf = snewn(len + 1, wchar_t);
        int n = 0;
        for (NSUInteger i = 0; i < len; i++)
            wbuf[n++] = (wchar_t)[str characterAtIndex:i];
        term_do_paste(s->term, wbuf, n);
        sfree(wbuf);
    }
}
static void cw_refresh(TermWin *tw)
{ [session_from_termwin(tw)->view setNeedsDisplay:YES]; }

static void cw_request_resize(TermWin *tw, int w, int h)
{
    CocoaSession *s = session_from_termwin(tw);
    [s->view recreateBackingForCols:w rows:h];
    term_size(s->term, h, w, conf_get_int(s->conf, CONF_savelines));
    NSWindow *win = s->view.window;
    if (win) {
        NSSize content = NSMakeSize(w * s->font_width, h * s->font_height);
        [win setContentSize:content];
    }
    term_resize_request_completed(s->term);
}

static void cw_set_title(TermWin *tw, const char *title, int codepage)
{
    CocoaSession *s = session_from_termwin(tw);
    NSString *t = [NSString stringWithUTF8String:title ? title : "PuTTY"];
    if (t && s->view.window) s->view.window.title = t;
}
static void cw_set_icon_title(TermWin *tw, const char *t, int cp) {}
static void cw_set_minimised(TermWin *tw, bool m)
{ NSWindow *w = session_from_termwin(tw)->view.window;
  if (m) [w miniaturize:nil]; else [w deminiaturize:nil]; }
static void cw_set_maximised(TermWin *tw, bool m) {}
static void cw_move(TermWin *tw, int x, int y) {}
static void cw_set_zorder(TermWin *tw, bool top)
{ if (top) [session_from_termwin(tw)->view.window orderFront:nil]; }

static void cw_palette_set(TermWin *tw, unsigned start, unsigned ncolours,
                           const rgb *colours)
{
    CocoaSession *s = session_from_termwin(tw);
    for (unsigned i = 0; i < ncolours && start+i < OSC4_NCOLOURS; i++)
        s->palette[start + i] = colours[i];
    [s->view setNeedsDisplay:YES];
}
static void cw_palette_get_overrides(TermWin *tw, Terminal *term) {}
static void cw_unthrottle(TermWin *tw, size_t bufsize)
{
    CocoaSession *s = session_from_termwin(tw);
    if (s->backend) backend_unthrottle(s->backend, bufsize);
}

static const TermWinVtable cocoa_termwin_vt = {
    .setup_draw_ctx = cw_setup_draw_ctx,
    .draw_text = cw_draw_text,
    .draw_cursor = cw_draw_cursor,
    .draw_trust_sigil = cw_draw_trust_sigil,
    .char_width = cw_char_width,
    .free_draw_ctx = cw_free_draw_ctx,
    .set_cursor_pos = cw_set_cursor_pos,
    .set_raw_mouse_mode = cw_set_raw_mouse_mode,
    .set_raw_mouse_mode_pointer = cw_set_raw_mouse_mode_pointer,
    .set_scrollbar = cw_set_scrollbar,
    .bell = cw_bell,
    .clip_write = cw_clip_write,
    .clip_request_paste = cw_clip_request_paste,
    .refresh = cw_refresh,
    .request_resize = cw_request_resize,
    .set_title = cw_set_title,
    .set_icon_title = cw_set_icon_title,
    .set_minimised = cw_set_minimised,
    .set_maximised = cw_set_maximised,
    .move = cw_move,
    .set_zorder = cw_set_zorder,
    .palette_set = cw_palette_set,
    .palette_get_overrides = cw_palette_get_overrides,
    .unthrottle = cw_unthrottle,
};

/* ==================================================================
 * Seat vtable.
 */

long g_test_rx_bytes = 0;     /* instrumentation for automated tests */

static size_t cs_output(Seat *seat, SeatOutputType type,
                        const void *data, size_t len)
{
    CocoaSession *s = session_from_seat(seat);
    g_test_rx_bytes += len;
    DBG("seat_output %zu bytes", len);
    return term_data(s->term, data, len);
}
static bool cs_eof(Seat *seat) { return true; }

/*
 * SSH authentication banners are sent outside the server's PTY, so they
 * are NOT subject to the usual LF->CRLF (ONLCR) conversion. Many servers
 * (e.g. rebex) end banner lines with a bare \n, which in a terminal moves
 * the cursor down WITHOUT returning to column 0 — leaving the following
 * password prompt stranded mid-line. So we display the banner with bare
 * LFs promoted to CRLF, matching how real PuTTY sanitises banners.
 */
static size_t cs_banner(Seat *seat, const void *data, size_t len)
{
    CocoaSession *s = session_from_seat(seat);
    const char *p = (const char *)data;
    char *out = snewn(len * 2, char);
    size_t n = 0;
    char prev = 0;
    for (size_t i = 0; i < len; i++) {
        if (p[i] == '\n' && prev != '\r')
            out[n++] = '\r';
        out[n++] = p[i];
        prev = p[i];
    }
    term_data(s->term, out, n);
    sfree(out);
    return 0;
}
static SeatPromptResult cs_get_userpass_input(Seat *seat, prompts_t *p)
{
    CocoaSession *s = session_from_seat(seat);
#if PUTTY_MAC_DEBUG
    DBG("userpass: name='%s' instruction='%s' nprompts=%zu cols=%d rows=%d",
        p->name ? p->name : "", p->instruction ? p->instruction : "",
        p->n_prompts, s->view ? s->view->cols : -1,
        s->view ? s->view->rows : -1);
    for (size_t i = 0; i < p->n_prompts; i++)
        DBG("  prompt[%zu]='%s'", i, p->prompts[i]->prompt);
#endif
    SeatPromptResult r = term_get_userpass_input(s->term, p);
    DBG("get_userpass_input -> kind=%d (n_prompts=%zu)", r.kind, p->n_prompts);
    return r;
}
static void cs_notify_remote_exit(Seat *seat)
{
    CocoaSession *s = session_from_seat(seat);
    if (s->backend && !backend_connected(s->backend)) {
        s->exited = true;
        s->exitcode = backend_exitcode(s->backend);
    }
}
static void cs_connection_fatal(Seat *seat, const char *msg)
{
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"PuTTY Fatal Error";
        a.informativeText = [NSString stringWithUTF8String:msg];
        a.alertStyle = NSAlertStyleCritical;
        [a runModal];
    }
}
static void cs_update_specials_menu(Seat *seat) {}
static char *cs_get_ttymode(Seat *seat, const char *mode)
{ return term_get_ttymode(session_from_seat(seat)->term, mode); }
static void cs_set_busy_status(Seat *seat, BusyStatus status) {}
static bool cs_is_utf8(Seat *seat)
{
    CocoaSession *s = session_from_seat(seat);
    return s->ucsdata.line_codepage == CS_UTF8;
}
static bool cs_get_window_pixel_size(Seat *seat, int *w, int *h)
{
    CocoaSession *s = session_from_seat(seat);
    *w = s->view->cols * s->font_width;
    *h = s->view->rows * s->font_height;
    return true;
}
static void cs_set_trust_status(Seat *seat, bool trusted)
{ term_set_trust_status(session_from_seat(seat)->term, trusted); }
static bool cs_get_cursor_position(Seat *seat, int *x, int *y)
{ term_get_cursor_position(session_from_seat(seat)->term, x, y); return true; }

/*
 * Asynchronous Yes/No confirmation built from a SeatDialogText.
 *
 * CRITICAL: these are called from *inside* the SSH backend while it is on
 * the call stack (during select_result). We must NOT run a nested modal
 * loop here, because that re-enters the SSH state machine and corrupts
 * it (symptom: connection appears to hang with a black terminal after
 * the host-key prompt). Instead we copy the message now, return
 * SPR_INCOMPLETE so the SSH stack unwinds, then present the dialog on a
 * later main-loop turn and resume the backend via its callback.
 */
static SeatPromptResult present_confirm_async(
    SeatDialogText *text, const char *title,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{
#if PUTTY_MAC_DEBUG
    if (getenv("PUTTY_TEST_SSH")) {     /* auto-accept during automated tests */
        dispatch_async(dispatch_get_main_queue(), ^{ callback(ctx, SPR_OK); });
        return SPR_INCOMPLETE;
    }
#endif

    /* Build the message text NOW; the SeatDialogText may be freed once we
     * return. The block captures these immutable copies. */
    NSMutableString *body = [[NSMutableString alloc] init];
    for (size_t i = 0; i < text->nitems; i++) {
        SeatDialogTextItem *it = &text->items[i];
        switch (it->type) {
          case SDT_PARA: case SDT_DISPLAY: case SDT_SCARY_HEADING:
          case SDT_PROMPT:
            [body appendFormat:@"%s\n", it->text]; break;
          case SDT_MORE_INFO_KEY:
            [body appendFormat:@"%s: ", it->text]; break;
          case SDT_MORE_INFO_VALUE_SHORT:
          case SDT_MORE_INFO_VALUE_BLOB:
            [body appendFormat:@"%s\n", it->text]; break;
          default: break;
        }
    }
    NSString *titleStr = [[NSString alloc] initWithUTF8String:title];

    DBG("confirm '%s': showing async dialog, returning INCOMPLETE", title);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = titleStr;
        a.informativeText = body;
        a.alertStyle = NSAlertStyleWarning;
        [a addButtonWithTitle:@"Accept"];
        [a addButtonWithTitle:@"Connect Once"];
        [a addButtonWithTitle:@"Cancel"];
        NSModalResponse resp = [a runModal];
        SeatPromptResult res =
            (resp == NSAlertFirstButtonReturn ||
             resp == NSAlertSecondButtonReturn) ? SPR_OK : SPR_USER_ABORT;
        DBG("confirm dialog answered (%ld), resuming backend",
            (long)resp);
        callback(ctx, res);
        DBG("backend resume callback returned");
    });
    return SPR_INCOMPLETE;
}

static SeatPromptResult cs_confirm_ssh_host_key(
    Seat *seat, const char *host, int port, const char *keytype,
    char *keystr, SeatDialogText *text, HelpCtx helpctx,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{ return present_confirm_async(text, "PuTTY Security Alert: Host Key",
                              callback, ctx); }

static SeatPromptResult cs_confirm_weak_crypto_primitive(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{ return present_confirm_async(text, "PuTTY Security Alert: Weak Crypto",
                              callback, ctx); }

static SeatPromptResult cs_confirm_weak_cached_hostkey(
    Seat *seat, SeatDialogText *text,
    void (*callback)(void *ctx, SeatPromptResult result), void *ctx)
{ return present_confirm_async(text, "PuTTY Security Alert: Weak Host Key",
                              callback, ctx); }

static const SeatVtable cocoa_seat_vt = {
    .output = cs_output,
    .eof = cs_eof,
    .sent = nullseat_sent,
    .banner = cs_banner,
    .get_userpass_input = cs_get_userpass_input,
    .notify_session_started = nullseat_notify_session_started,
    .notify_remote_exit = cs_notify_remote_exit,
    .notify_remote_disconnect = nullseat_notify_remote_disconnect,
    .connection_fatal = cs_connection_fatal,
    .nonfatal = nullseat_nonfatal,
    .update_specials_menu = cs_update_specials_menu,
    .get_ttymode = cs_get_ttymode,
    .set_busy_status = cs_set_busy_status,
    .confirm_ssh_host_key = cs_confirm_ssh_host_key,
    .confirm_weak_crypto_primitive = cs_confirm_weak_crypto_primitive,
    .confirm_weak_cached_hostkey = cs_confirm_weak_cached_hostkey,
    .prompt_descriptions = nullseat_prompt_descriptions,
    .is_utf8 = cs_is_utf8,
    .echoedit_update = nullseat_echoedit_update,
    .get_display = nullseat_get_display,
    .get_windowid = nullseat_get_windowid,
    .get_window_pixel_size = cs_get_window_pixel_size,
    .stripctrl_new = nullseat_stripctrl_new,
    .set_trust_status = cs_set_trust_status,
    .can_set_trust_status = nullseat_can_set_trust_status_yes,
    .has_mixed_input_stream = nullseat_has_mixed_input_stream_yes,
    .verbose = nullseat_verbose_yes,
    .interactive = nullseat_interactive_yes,
    .get_cursor_position = cs_get_cursor_position,
};

/* ==================================================================
 * LogPolicy vtable.
 */

static void clp_eventlog(LogPolicy *lp, const char *event) {}
static int clp_askappend(LogPolicy *lp, Filename *filename,
                         void (*callback)(void *ctx, int result), void *ctx)
{ return 2; /* always overwrite */ }
static void clp_logging_error(LogPolicy *lp, const char *event)
{ fprintf(stderr, "logging error: %s\n", event); }

static const LogPolicyVtable cocoa_logpolicy_vt = {
    .eventlog = clp_eventlog,
    .askappend = clp_askappend,
    .logging_error = clp_logging_error,
    .verbose = null_lp_verbose_yes,
};

/* ==================================================================
 * Session lifecycle.
 */

CocoaSession *cocoa_session_new(Conf *conf, PuTTYTerminalView *view,
                                PuTTYWindowController *controller,
                                char **error)
{
    CocoaSession *s = snew(CocoaSession);
    memset(s, 0, sizeof(*s));
    s->conf = conf;
    s->seat.vt = &cocoa_seat_vt;
    s->termwin.vt = &cocoa_termwin_vt;
    s->logpolicy.vt = &cocoa_logpolicy_vt;
    s->view = view;
    s->controller = controller;
    view->sess = s;

    /* default palette so we can draw before the terminal sets it */
    for (int i = 0; i < OSC4_NCOLOURS; i++) {
        s->palette[i].r = s->palette[i].g = s->palette[i].b =
            (i == 258 || i == 259) ? 0 : 200;
    }

    init_ucs_generic(conf, &s->ucsdata);
    [view remeasureFont];

    s->term = term_init(conf, &s->ucsdata, &s->termwin);

    /*
     * Wire the terminal's clipboards to the macOS system pasteboard.
     * mouse_select_clipboards[0] is always CLIP_LOCAL (the terminal's
     * own selection buffer); we additionally copy selections to, and
     * paste from, CLIP_CLIPBOARD, which our win_clip_write /
     * win_clip_request_paste implementations map to NSPasteboard. This
     * is the equivalent of GTK's setup_clipboards().
     */
    s->term->n_mouse_select_clipboards = 1;
    s->term->mouse_select_clipboards[s->term->n_mouse_select_clipboards++] =
        CLIP_CLIPBOARD;
    s->term->mouse_paste_clipboard = CLIP_CLIPBOARD;

    s->logctx = log_init(&s->logpolicy, conf);
    term_provide_logctx(s->term, s->logctx);

    int width = conf_get_int(conf, CONF_width);
    int height = conf_get_int(conf, CONF_height);
    [view recreateBackingForCols:width rows:height];
    term_size(s->term, height, width, conf_get_int(conf, CONF_savelines));

    /* start the backend */
    const struct BackendVtable *vt = backend_vt_from_proto(
        conf_get_int(conf, CONF_protocol));
    if (!vt) {
        if (error) *error = dupstr("Unknown protocol");
        return s;            /* still return; window shows empty terminal */
    }
    char *realhost = NULL;
    char *err = backend_init(
        vt, &s->seat, &s->backend, s->logctx, conf,
        conf_get_str(conf, CONF_host), conf_get_int(conf, CONF_port),
        &realhost,
        conf_get_bool(conf, CONF_tcp_nodelay),
        conf_get_bool(conf, CONF_tcp_keepalives));
    if (err) {
        DBG("backend_init FAILED: %s", err);
        if (error) *error = err;     /* caller shows it */
    } else {
        s->ldisc = ldisc_create(conf, s->term, s->backend, &s->seat);
        term_provide_backend(s->term, s->backend);
        backend_size(s->backend, width, height);
        DBG("backend_init OK, ldisc=%p connected=%d",
            (void*)s->ldisc, s->backend ? backend_connected(s->backend) : 0);
    }
    sfree(realhost);
    return s;
}

void cocoa_session_send(CocoaSession *s, const char *buf, int len)
{
    DBG("session_send %d bytes", len);
    send_keys(s, buf, len, false);   /* ordinary (non-dedicated) input */
}

void cocoa_session_set_focus(CocoaSession *s, bool focused)
{ if (s && s->term) term_set_focus(s->term, focused); }

#if PUTTY_MAC_DEBUG
/* Test helper: count non-background pixels in the backing store, to
 * verify the paint path actually drew something. */
long cocoa_test_painted_pixels(CocoaSession *s)
{
    if (!s || !s->view || !s->view->backing) return -1;
    CGContextRef c = s->view->backing;
    unsigned char *data = CGBitmapContextGetData(c);
    if (!data) return -2;
    size_t w = CGBitmapContextGetWidth(c), h = CGBitmapContextGetHeight(c);
    size_t bpr = CGBitmapContextGetBytesPerRow(c);
    long count = 0;
    for (size_t y = 0; y < h; y++) {
        unsigned char *row = data + y * bpr;
        for (size_t x = 0; x < w; x++) {
            unsigned char *px = row + x * 4;
            if (px[0] > 20 || px[1] > 20 || px[2] > 20) count++;
        }
    }
    return count;
}

/* Test helper: force the view's drawRect: into an offscreen bitmap and
 * count non-background pixels, to verify the visible blit path works. */
long cocoa_test_drawrect_pixels(CocoaSession *s)
{
    if (!s || !s->view) return -1;
    PuTTYTerminalView *v = s->view;
    NSRect b = v.bounds;
    if (b.size.width < 1 || b.size.height < 1) return -2;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:b];
    if (!rep) return -3;
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    long count = 0;
    NSInteger w = rep.pixelsWide, h = rep.pixelsHigh;
    for (NSInteger y = 0; y < h; y += 2)
        for (NSInteger x = 0; x < w; x += 2) {
            NSColor *px = [rep colorAtX:x y:y];
            if (px && (px.redComponent > 0.08 || px.greenComponent > 0.08 ||
                       px.blueComponent > 0.08))
                count++;
        }
    return count;
}

/* Test helper: write the backing store to a PNG so the rendering can be
 * inspected without a visible window. */
void cocoa_test_dump_png(CocoaSession *s, const char *path)
{
    if (!s || !s->view || !s->view->backing) return;
    CGImageRef img = CGBitmapContextCreateImage(s->view->backing);
    if (!img) return;
    CFStringRef p = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, p, kCFURLPOSIXPathStyle,
                                                 false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        url, CFSTR("public.png"), 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url); CFRelease(p); CGImageRelease(img);
}
#endif /* PUTTY_MAC_DEBUG */

void cocoa_session_free(CocoaSession *s)
{
    if (!s) return;
    if (s->ldisc) ldisc_free(s->ldisc);
    if (s->backend) backend_free(s->backend);
    if (s->logctx) log_free(s->logctx);
    if (s->term) term_free(s->term);
    if (s->conf) conf_free(s->conf);
    sfree(s);
}
