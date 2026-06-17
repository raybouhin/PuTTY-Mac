/*
 * cocoa-dialog.m: native renderer for PuTTY's data-driven configuration
 * dialog.
 *
 * PuTTY describes its entire configuration UI (every panel and control)
 * in portable code (config.c -> controlbox/controlset/dlgcontrol). Each
 * platform implements the dlg_* interface to render those controls and
 * the EVENT_* handler protocol to load/store values. This file is the
 * macOS/AppKit implementation, giving us the full PuTTY config tree
 * (Session, Terminal, Window, Connection, SSH, Auth, Tunnels, ...) 1:1
 * with the same options as every other PuTTY, drawn with native Cocoa
 * widgets and dark mode.
 */

#import <Cocoa/Cocoa.h>

#include "cocoa-platform.h"
#include "dialog.h"
#include "ssh.h"

@class UCtrl;
@class CocoaDlg;

/* A top-left-origin content view so controls lay out top-to-bottom. */
@interface FlippedContent : NSView @end
@implementation FlippedContent - (BOOL)isFlipped { return YES; } @end

/* A scroll view (used for embedded list boxes) that forwards the mouse
 * wheel to the enclosing scroll view when its own content can't scroll.
 * Without this, hovering over a short list box (e.g. the saved-sessions
 * list) swallows the wheel and the surrounding config panel won't scroll. */
@interface PassthroughScrollView : NSScrollView @end
@implementation PassthroughScrollView
- (void)scrollWheel:(NSEvent *)event
{
    NSView *doc = self.documentView;
    BOOL canScroll = doc &&
        doc.frame.size.height > self.contentView.bounds.size.height + 1.0;
    if (!canScroll) {
        [self.enclosingScrollView scrollWheel:event];
        return;
    }
    [super scrollWheel:event];
}
@end

/* A scroller that draws its own slim, dark, translucent knob and no track.
 * This is needed because when the system "Show scroll bars" setting is
 * "Always", AppKit uses fat light legacy scrollers and ignores per-view
 * style/knob overrides; drawing the knob ourselves gives a consistent
 * slim dark thumb that blends into the dark theme. */
@interface SlimDarkScroller : NSScroller @end
@implementation SlimDarkScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return YES; }
+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)cs
                          scrollerStyle:(NSScrollerStyle)st
{ return 11.0; }
- (void)drawKnobSlotInRect:(NSRect)slotRect highlight:(BOOL)flag
{ /* no track */ }
- (void)drawKnob
{
    NSRect knob = [self rectForPart:NSScrollerKnob];
    knob = NSInsetRect(knob, 3, 3);
    CGFloat radius = MIN(knob.size.width, knob.size.height) / 2.0;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:knob
                                                     xRadius:radius
                                                     yRadius:radius];
    [[NSColor colorWithWhite:0.40 alpha:0.85] set];
    [p fill];
}
@end

/* Install slim dark scrollers on a scroll view. */
static void style_dark_scrollers(NSScrollView *sv)
{
    sv.scrollerStyle = NSScrollerStyleOverlay;
    SlimDarkScroller *vs = [[SlimDarkScroller alloc]
        initWithFrame:NSMakeRect(0, 0, 11, 100)];
    sv.verticalScroller = vs;
    sv.hasVerticalScroller = YES;
}

/* Platform-opaque dialog state, as referenced by the dlg_* functions. */
struct dlgparam {
    void *data;                  /* the Conf being edited */
    int retval;
    bool ended;
    CocoaDlg *gui;               /* the Objective-C controller (retained) */
};

/* ------------------------------------------------------------------
 * Per-control wrapper, mapping one dlgcontrol to its Cocoa widget(s).
 */
@interface UCtrl : NSObject
{
@public
    dlgcontrol *ctrl;
    NSView *toplevel;            /* row container */
    NSTextField *entry;          /* editbox / filesel / fontsel field */
    NSButton *checkbox;          /* checkbox */
    NSMutableArray *radios;      /* NSButton* for radio group */
    NSPopUpButton *popup;        /* dropdown listbox or has_list combo */
    NSComboBox *combo;           /* editable combo (editbox has_list) */
    NSTableView *table;          /* listbox */
    NSMutableArray *items;       /* NSArray of @[text, @id] for listbox */
    NSTextField *label;          /* CTRL_TEXT / labels we may relabel */
    NSButton *pushbutton;        /* CTRL_BUTTON */
    Filename *filename;          /* filesel value */
    FontSpec *fontspec;          /* fontsel value */
}
@end
@implementation UCtrl @end

/* ------------------------------------------------------------------
 * The dialog controller: builds the window, owns the controlbox,
 * implements the tree (NSOutlineView) and the per-panel content, and
 * acts as the target/delegate for all controls.
 */

@interface TreeNode : NSObject
{ @public NSString *name; NSString *path; NSMutableArray *children; }
@end
@implementation TreeNode @end

@interface CocoaDlg : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSTableViewDataSource, NSTableViewDelegate,
                                NSTextFieldDelegate, NSComboBoxDelegate,
                                NSWindowDelegate>
{
@public
    struct dlgparam *dp;
    struct controlbox *ctrlbox;
    NSWindow *window;
    NSOutlineView *tree;
    NSView *contentView;         /* right-hand panel area (flipped) */
    NSScrollView *contentScroll;
    TreeNode *root;
    NSMutableArray *flatNodes;   /* DFS order for outline */
    NSMapTable *byctrl;          /* dlgcontrol* -> UCtrl* (current panel) */
    NSMapTable *actionCtrls;     /* dlgcontrol* -> UCtrl* (persistent buttons) */
    NSString *currentPath;
    void (^onDone)(int retval);  /* completion, called when dialog ends */
    BOOL finished;
}
- (void)buildTree;
- (void)showPanel:(NSString *)path;
- (UCtrl *)uctrlFor:(dlgcontrol *)c;
- (void)teardownPanel;
- (void)finishWithRetval:(int)v;
@end

/* Open (non-modal) config dialogs, retained while on screen. */
static NSMutableArray *g_openConfigs;

/* current dialog (single modal at a time) so dlg_* C functions can find
 * the controller from the dlgparam. */
static CocoaDlg *g_active_dlg;

@implementation CocoaDlg

- (UCtrl *)uctrlFor:(dlgcontrol *)c
{
    NSValue *k = [NSValue valueWithPointer:c];
    UCtrl *uc = [byctrl objectForKey:k];
    if (!uc) uc = [actionCtrls objectForKey:k];
    return uc;
}

/* Tear down the current panel: detach table data sources (so a late
 * redraw can't call back into freed state) and drop the per-panel control
 * map. The persistent action buttons in actionCtrls are left intact. */
- (void)teardownPanel
{
    for (NSView *v in [contentView.subviews copy]) {
        if ([v isKindOfClass:[NSScrollView class]]) {
            id doc = [(NSScrollView *)v documentView];
            if ([doc isKindOfClass:[NSTableView class]]) {
                [(NSTableView *)doc setDataSource:nil];
                [(NSTableView *)doc setDelegate:nil];
            }
        }
        [v removeFromSuperview];
    }
    [byctrl removeAllObjects];
}

/* End the dialog with a return value. Deferred to the next run-loop turn
 * so we never tear down views while they're mid-event-dispatch (which is
 * how a button's own click handler reaches here). */
- (void)finishWithRetval:(int)v
{
    if (finished) return;
    finished = YES;
    [window orderOut:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [self reallyFinish:v]; });
}
- (void)reallyFinish:(int)v
{
    tree.dataSource = nil; tree.delegate = nil;
    [self teardownPanel];
    [actionCtrls removeAllObjects];
    window.delegate = nil;
    window.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    if (g_active_dlg == self) g_active_dlg = nil;
    if (ctrlbox) { ctrl_free_box(ctrlbox); ctrlbox = NULL; }
    void (^done)(int) = onDone; onDone = nil;
    struct dlgparam *d = dp; dp = NULL;
    if (done) done(v);          /* may open a terminal window (Open) */
    if (d) free(d);
    [g_openConfigs removeObject:self];   /* may release self last */
    cocoa_maybe_quit();         /* quit if nothing left open */
}

int cocoa_config_box_count(void)
{
    return (int)(g_openConfigs ? g_openConfigs.count : 0);
}

/* Red close button == Cancel. */
- (void)windowWillClose:(NSNotification *)n { [self finishWithRetval:0]; }

/* ---- build the panel tree from controlset pathnames ---- */

- (TreeNode *)nodeForPath:(NSString *)path create:(BOOL)create
{
    if (path.length == 0) return root;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    TreeNode *cur = root;
    NSMutableString *acc = [NSMutableString string];
    for (NSString *p in parts) {
        if (acc.length) [acc appendString:@"/"];
        [acc appendString:p];
        TreeNode *found = nil;
        for (TreeNode *ch in cur->children)
            if ([ch->name isEqualToString:p]) { found = ch; break; }
        if (!found) {
            if (!create) return nil;
            found = [[TreeNode alloc] init];
            found->name = [p copy];
            found->path = [acc copy];
            found->children = [[NSMutableArray alloc] init];
            [cur->children addObject:found];
        }
        cur = found;
    }
    return cur;
}

- (void)buildTree
{
    root = [[TreeNode alloc] init];
    root->children = [[NSMutableArray alloc] init];
    for (size_t i = 0; i < ctrlbox->nctrlsets; i++) {
        struct controlset *s = ctrlbox->ctrlsets[i];
        if (s->pathname && *s->pathname)
            [self nodeForPath:[NSString stringWithUTF8String:s->pathname]
                       create:YES];
    }
}

/* ---- NSOutlineView data source ---- */
- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item
{ TreeNode *n = item ?: root; return n ? n->children.count : 0; }
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)idx ofItem:(id)item
{ TreeNode *n = item ?: root; return n->children[idx]; }
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item
{ TreeNode *n = item; return n->children.count > 0; }
- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)c
             byItem:(id)item
{ TreeNode *n = item; return n->name; }
- (void)outlineViewSelectionDidChange:(NSNotification *)note
{
    TreeNode *n = [tree itemAtRow:tree.selectedRow];
    if (n) [self showPanel:n->path];
}

/* ---- panel layout ---- */

- (void)showPanel:(NSString *)path
{
    currentPath = [path copy];
    [self teardownPanel];

    const CGFloat pad = 14, rowGap = 8, colGap = 10;
    CGFloat totalW = contentScroll.contentSize.width;
    if (totalW < 200) totalW = 472;
    CGFloat inner = totalW - 2*pad;
    CGFloat top = 12;

    for (size_t i = 0; i < ctrlbox->nctrlsets; i++) {
        struct controlset *s = ctrlbox->ctrlsets[i];
        if (!s->pathname || strcmp(s->pathname, path.UTF8String) != 0)
            continue;

        if (s->boxtitle) {
            NSTextField *t = [NSTextField labelWithString:
                [NSString stringWithUTF8String:s->boxtitle]];
            t.font = [NSFont boldSystemFontOfSize:13];
            t.frame = NSMakeRect(pad, top, inner, 20);
            [contentView addSubview:t]; top += 26;
        }

        /* Column layout state for this controlset, driven by CTRL_COLUMNS.
         * Each column tracks its own running y so controls can sit side by
         * side (e.g. the session list at 75% with Load/Save/Delete stacked
         * in the 25% column beside it). */
        int ncols = 1;
        CGFloat frac[16]; frac[0] = 1.0;
        CGFloat colY[16]; colY[0] = top;

        for (size_t j = 0; j < s->ncontrols; j++) {
            dlgcontrol *ctrl = s->ctrls[j];

            if (ctrl->type == CTRL_COLUMNS) {
                CGFloat maxy = colY[0];
                for (int k = 1; k < ncols; k++)
                    if (colY[k] > maxy) maxy = colY[k];
                int n = ctrl->columns.ncols;
                if (n < 1) n = 1; if (n > 16) n = 16;
                ncols = n;
                for (int k = 0; k < n; k++)
                    frac[k] = (ctrl->columns.percentages ?
                               ctrl->columns.percentages[k] : (100.0/n)) / 100.0;
                for (int k = 0; k < n; k++) colY[k] = maxy;
                continue;
            }
            if (ctrl->type == CTRL_TABDELAY)
                continue;

            int start = COLUMN_START(ctrl->column);
            int span = COLUMN_SPAN(ctrl->column);
            if (start < 0) start = 0;
            if (start >= ncols) start = ncols - 1;
            if (span < 1) span = 1;
            if (start + span > ncols) span = ncols - start;

            CGFloat xfrac = 0; for (int k = 0; k < start; k++) xfrac += frac[k];
            CGFloat wfrac = 0; for (int k = start; k < start+span; k++) wfrac += frac[k];
            CGFloat x = pad + xfrac * inner;
            CGFloat w = wfrac * inner - (ncols > 1 ? colGap : 0);
            CGFloat placeY = colY[start];
            for (int k = start; k < start+span; k++)
                if (colY[k] > placeY) placeY = colY[k];

            CGFloat h = [self layoutControl:ctrl atX:x y:placeY width:w];
            CGFloat newY = placeY + h + rowGap;
            for (int k = start; k < start+span; k++) colY[k] = newY;
        }

        CGFloat maxy = colY[0];
        for (int k = 1; k < ncols; k++) if (colY[k] > maxy) maxy = colY[k];
        top = maxy + 6;
    }

    NSRect cf = contentView.frame;
    cf.size.height = MAX(top + 12, contentScroll.contentSize.height);
    cf.size.width = contentScroll.contentSize.width;
    contentView.frame = cf;

    /* refresh values from Conf for every control we just built */
    dlg_refresh(NULL, dp);
}

/* Lay out one control within the rectangle (x, y, width); returns the
 * height it consumed. */
- (CGFloat)layoutControl:(dlgcontrol *)ctrl atX:(CGFloat)x y:(CGFloat)y
                   width:(CGFloat)width
{
    const CGFloat ctlH = 22;
    NSString *lbl = ctrl->label ?
        [NSString stringWithUTF8String:ctrl->label] : @"";
    UCtrl *uc = [[UCtrl alloc] init];
    uc->ctrl = ctrl;
    CGFloat cy = y;

    switch (ctrl->type) {
      case CTRL_TEXT: {
        NSTextField *t = [NSTextField wrappingLabelWithString:lbl];
        t.preferredMaxLayoutWidth = width;
        NSSize sz = [t sizeThatFits:NSMakeSize(width, 1000)];
        CGFloat h = MAX(sz.height, 16);
        t.frame = NSMakeRect(x, cy, width, h);
        t.toolTip = lbl;
        [contentView addSubview:t]; uc->label = t;
        cy += h;
        break;
      }
      case CTRL_CHECKBOX: {
        NSButton *b = [NSButton checkboxWithTitle:lbl target:self
                                           action:@selector(ctlChanged:)];
        b.frame = NSMakeRect(x, cy, width, ctlH);
        b.toolTip = lbl;            /* full text on hover when truncated */
        [contentView addSubview:b]; uc->checkbox = b;
        cy += ctlH;
        break;
      }
      case CTRL_BUTTON: {
        NSButton *b = [NSButton buttonWithTitle:lbl target:self
                                         action:@selector(ctlAction:)];
        b.bezelStyle = NSBezelStyleRounded;
        b.frame = NSMakeRect(x, cy, width, 28);
        b.toolTip = lbl;
        [contentView addSubview:b]; uc->pushbutton = b;
        cy += 28;
        break;
      }
      case CTRL_EDITBOX: {
        bool wholeline = (ctrl->editbox.percentwidth >= 100);
        CGFloat fx = x, fw = width, fy = cy;
        if (lbl.length) {
            if (wholeline) {
                NSTextField *l = [NSTextField labelWithString:lbl];
                l.frame = NSMakeRect(x, cy, width, ctlH);
                [contentView addSubview:l]; uc->label = l;
                fy = cy + ctlH + 2;
            } else {
                CGFloat lblW = MIN(150, width * 0.5);
                NSTextField *l = [NSTextField labelWithString:lbl];
                l.frame = NSMakeRect(x, cy, lblW, ctlH);
                [contentView addSubview:l]; uc->label = l;
                fx = x + lblW + 6; fw = width - lblW - 6;
            }
        }
        if (ctrl->editbox.has_list) {
            NSComboBox *cb = [[NSComboBox alloc]
                initWithFrame:NSMakeRect(fx, fy, fw, ctlH)];
            cb.delegate = self; cb.target = self;
            cb.action = @selector(ctlChanged:);
            [contentView addSubview:cb]; uc->combo = cb;
        } else {
            NSTextField *e = ctrl->editbox.password ?
                [[NSSecureTextField alloc]
                    initWithFrame:NSMakeRect(fx, fy, fw, ctlH)] :
                [[NSTextField alloc]
                    initWithFrame:NSMakeRect(fx, fy, fw, ctlH)];
            e.delegate = self;
            [contentView addSubview:e]; uc->entry = e;
        }
        cy = fy + ctlH;
        break;
      }
      case CTRL_RADIO: {
        if (lbl.length) {
            NSTextField *l = [NSTextField labelWithString:lbl];
            l.frame = NSMakeRect(x, cy, width, ctlH);
            [contentView addSubview:l]; uc->label = l;
            cy += ctlH + 2;
        }
        uc->radios = [[NSMutableArray alloc] init];
        int rcols = ctrl->radio.ncolumns > 0 ? ctrl->radio.ncolumns : 1;
        CGFloat colW = width / rcols;
        int rows = (ctrl->radio.nbuttons + rcols - 1) / rcols;
        /* Put this group's buttons in their OWN flipped container view.
         * AppKit auto-groups radio buttons that share an action AND a
         * superview, so without separate containers every radio button in
         * the whole panel would become one mutually-exclusive group --
         * and refreshing one group (e.g. "Close window on exit") would
         * silently clear another (e.g. the SSH connection-type radio). */
        FlippedContent *group = [[FlippedContent alloc]
            initWithFrame:NSMakeRect(x, cy, width, rows*ctlH)];
        for (int b = 0; b < ctrl->radio.nbuttons; b++) {
            int col = b % rcols, row = b / rcols;
            NSString *bt = [NSString stringWithUTF8String:
                            ctrl->radio.buttons[b]];
            NSButton *rb = [NSButton radioButtonWithTitle:bt target:self
                                                   action:@selector(ctlChanged:)];
            rb.frame = NSMakeRect(col*colW, row*ctlH, colW, ctlH);
            rb.toolTip = bt;        /* full text on hover when truncated */
            rb.tag = b;
            [group addSubview:rb];
            [uc->radios addObject:rb];
        }
        [contentView addSubview:group];
        cy += rows*ctlH;
        break;
      }
      case CTRL_LISTBOX: {
        if (lbl.length) {
            NSTextField *l = [NSTextField labelWithString:lbl];
            l.frame = NSMakeRect(x, cy, width, ctlH);
            [contentView addSubview:l]; uc->label = l;
            cy += ctlH + 2;
        }
        uc->items = [[NSMutableArray alloc] init];
        if (ctrl->listbox.height == 0) {
            NSPopUpButton *pb = [[NSPopUpButton alloc]
                initWithFrame:NSMakeRect(x, cy, width, ctlH)];
            pb.target = self; pb.action = @selector(ctlChanged:);
            [contentView addSubview:pb]; uc->popup = pb;
            cy += ctlH;
        } else {
            CGFloat h = ctrl->listbox.height * 18 + 8;
            PassthroughScrollView *sv = [[PassthroughScrollView alloc]
                initWithFrame:NSMakeRect(x, cy, width, h)];
            sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
            style_dark_scrollers(sv);
            NSTableView *tv = [[NSTableView alloc] initWithFrame:sv.bounds];
            NSTableColumn *col = [[NSTableColumn alloc]
                                  initWithIdentifier:@"c"];
            col.width = width - 20;
            [tv addTableColumn:col];
            tv.headerView = nil;
            tv.dataSource = self; tv.delegate = self;
            tv.allowsMultipleSelection = (ctrl->listbox.multisel != 0);
            tv.target = self; tv.doubleAction = @selector(ctlAction:);
            sv.documentView = tv;
            [contentView addSubview:sv]; uc->table = tv;
            cy += h;
        }
        break;
      }
      case CTRL_FILESELECT:
      case CTRL_FONTSELECT: {
        CGFloat fx = x, fw = width;
        if (lbl.length) {
            CGFloat lblW = MIN(150, width * 0.4);
            NSTextField *l = [NSTextField labelWithString:lbl];
            l.frame = NSMakeRect(x, cy, lblW, ctlH);
            [contentView addSubview:l]; uc->label = l;
            fx = x + lblW + 6; fw = width - lblW - 6;
        }
        CGFloat btnW = 84;
        NSTextField *e = [[NSTextField alloc]
            initWithFrame:NSMakeRect(fx, cy, fw - btnW - 6, ctlH)];
        e.editable = NO;
        [contentView addSubview:e]; uc->entry = e;
        NSButton *br = [NSButton buttonWithTitle:
            (ctrl->type == CTRL_FILESELECT ? @"Browse…" : @"Change…")
            target:self action:@selector(ctlAction:)];
        br.bezelStyle = NSBezelStyleRounded;
        br.frame = NSMakeRect(fx + fw - btnW, cy - 3, btnW, 26);
        [contentView addSubview:br]; uc->pushbutton = br;
        cy += ctlH;
        break;
      }
      default:
        break;
    }

    [byctrl setObject:uc forKey:[NSValue valueWithPointer:ctrl]];
    return cy - y;
}

/* ---- map a Cocoa sender back to its UCtrl ---- */
- (UCtrl *)uctrlForSender:(id)sender inMap:(NSMapTable *)map
{
    for (NSValue *k in map) {
        UCtrl *uc = [map objectForKey:k];
        if (uc->checkbox == sender || uc->entry == sender ||
            uc->combo == sender || uc->popup == sender ||
            uc->pushbutton == sender || uc->table == sender ||
            [uc->radios containsObject:sender])
            return uc;
    }
    return nil;
}
- (UCtrl *)uctrlForSender:(id)sender
{
    UCtrl *uc = [self uctrlForSender:sender inMap:byctrl];
    if (!uc) uc = [self uctrlForSender:sender inMap:actionCtrls];
    return uc;
}

- (void)fire:(dlgcontrol *)c event:(int)ev
{ if (c->handler) c->handler(c, dp, dp->data, ev); }

- (void)ctlChanged:(id)sender
{
    UCtrl *uc = [self uctrlForSender:sender];
    if (!uc) return;
    int ev = (uc->popup || uc->table) ? EVENT_SELCHANGE : EVENT_VALCHANGE;
    [self fire:uc->ctrl event:ev];
}
- (void)ctlAction:(id)sender
{
    UCtrl *uc = [self uctrlForSender:sender];
    if (!uc) return;
    if (uc->ctrl->type == CTRL_FILESELECT) { [self browseFile:uc]; return; }
    if (uc->ctrl->type == CTRL_FONTSELECT) { [self browseFont:uc]; return; }
    [self fire:uc->ctrl event:EVENT_ACTION];
}

/* live editbox edits */
- (void)controlTextDidChange:(NSNotification *)n
{
    UCtrl *uc = [self uctrlForSender:n.object];
    if (uc) [self fire:uc->ctrl event:EVENT_VALCHANGE];
}

/* table selection -> SELCHANGE */
- (void)tableViewSelectionDidChange:(NSNotification *)n
{
    UCtrl *uc = [self uctrlForSender:n.object];
    if (uc) [self fire:uc->ctrl event:EVENT_SELCHANGE];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{ UCtrl *uc = [self uctrlForSender:tv]; return uc ? uc->items.count : 0; }
- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)c
            row:(NSInteger)row
{ UCtrl *uc = [self uctrlForSender:tv];
  return uc ? uc->items[row][0] : @""; }

/* file/font pickers */
- (void)browseFile:(UCtrl *)uc
{
    NSSavePanel *panel;
    if (uc->ctrl->fileselect.for_writing) panel = [NSSavePanel savePanel];
    else panel = [NSOpenPanel openPanel];
    if ([panel runModal] == NSModalResponseOK) {
        const char *p = panel.URL.path.UTF8String;
        if (uc->filename) filename_free(uc->filename);
        uc->filename = filename_from_str(p);
        uc->entry.stringValue = panel.URL.path;
        [self fire:uc->ctrl event:EVENT_VALCHANGE];
    }
}
- (void)browseFont:(UCtrl *)uc
{
    NSFontPanel *fp = [NSFontPanel sharedFontPanel];
    [fp makeKeyAndOrderFront:nil];
    /* A full font-panel round trip is elaborate; for now keep the
     * configured value. The terminal font can also be set via Conf. */
}

/* ---- bottom buttons (the "" controlset) ---- */
- (void)addActionButtonsTo:(NSView *)bar width:(CGFloat)w
{
    CGFloat x = w - 12;
    for (size_t i = 0; i < ctrlbox->nctrlsets; i++) {
        struct controlset *s = ctrlbox->ctrlsets[i];
        if (s->pathname && *s->pathname) continue;
        for (size_t j = 0; j < s->ncontrols; j++) {
            dlgcontrol *ctrl = s->ctrls[j];
            if (ctrl->type != CTRL_BUTTON) continue;
            NSString *t = [NSString stringWithUTF8String:
                           ctrl->label ? ctrl->label : "Button"];
            NSButton *b = [NSButton buttonWithTitle:t target:self
                                             action:@selector(ctlAction:)];
            b.bezelStyle = NSBezelStyleRounded;
            CGFloat bw = MAX(90, t.length*9.0);
            b.frame = NSMakeRect(x - bw, 12, bw, 30);
            x -= bw + 8;
            if (ctrl->button.isdefault) b.keyEquivalent = @"\r";
            [bar addSubview:b];
            UCtrl *uc = [[UCtrl alloc] init];
            uc->ctrl = ctrl; uc->pushbutton = b;
            [actionCtrls setObject:uc forKey:[NSValue valueWithPointer:ctrl]];
        }
    }
}

@end

/* ==================================================================
 * Entry point.
 */

void cocoa_open_config_box(const char *title, Conf *conf,
                           bool midsession, int protcfginfo,
                           void (^completion)(bool ok))
{
    @autoreleasepool {
        struct dlgparam *dp = (struct dlgparam *)calloc(1, sizeof(*dp));
        dp->data = conf;
        dp->retval = 0;

        struct controlbox *cb = ctrl_new_box();
        int proto = conf_get_int(conf, CONF_protocol);
        setup_config_box(cb, midsession, proto, protcfginfo);

        CocoaDlg *gui = [[CocoaDlg alloc] init];
        gui->dp = dp;
        gui->ctrlbox = cb;
        /* Retain: these are autoreleased convenience objects, and this
         * dialog is now non-modal, so they must outlive the autorelease
         * pool that drains when this function returns. */
        gui->byctrl = [[NSMapTable strongToStrongObjectsMapTable] retain];
        gui->actionCtrls = [[NSMapTable strongToStrongObjectsMapTable] retain];
        gui->onDone = [completion copy];
        dp->gui = gui;
        g_active_dlg = gui;
        if (!g_openConfigs) g_openConfigs = [[NSMutableArray alloc] init];
        [g_openConfigs addObject:gui];
        [gui buildTree];          /* must precede any outline reloadData */

        NSRect frame = NSMakeRect(0, 0, 720, 520);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskResizable;
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
            styleMask:style backing:NSBackingStoreBuffered defer:NO];
        win.title = [NSString stringWithUTF8String:title];
        win.delegate = gui;
        win.releasedWhenClosed = NO;
        gui->window = win;

        NSView *cv = win.contentView;

        /* left: tree */
        NSScrollView *treeScroll = [[NSScrollView alloc]
            initWithFrame:NSMakeRect(0, 54, 220, frame.size.height-54)];
        treeScroll.hasVerticalScroller = YES;
        treeScroll.autoresizingMask = NSViewHeightSizable;
        treeScroll.borderType = NSBezelBorder;
        style_dark_scrollers(treeScroll);
        NSOutlineView *ov = [[NSOutlineView alloc] initWithFrame:treeScroll.bounds];
        NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:@"t"];
        tc.width = 200;
        [ov addTableColumn:tc];
        ov.outlineTableColumn = tc;
        ov.headerView = nil;
        ov.dataSource = gui; ov.delegate = gui;
        /* No blue focus ring around the sidebar (it's a navigation list,
         * not a text input). */
        ov.focusRingType = NSFocusRingTypeNone;
        treeScroll.focusRingType = NSFocusRingTypeNone;
        treeScroll.documentView = ov;
        gui->tree = ov;
        [cv addSubview:treeScroll];

        /* right: content scroll */
        NSScrollView *cs = [[NSScrollView alloc]
            initWithFrame:NSMakeRect(224, 54, frame.size.width-224,
                                     frame.size.height-54)];
        cs.hasVerticalScroller = YES;
        cs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        cs.drawsBackground = NO;
        style_dark_scrollers(cs);
        FlippedContent *content = [[FlippedContent alloc] initWithFrame:
            NSMakeRect(0,0,cs.contentSize.width,cs.contentSize.height)];
        gui->contentScroll = cs;
        gui->contentView = content;
        cs.documentView = content;
        [cv addSubview:cs];

        /* bottom: action bar */
        NSView *bar = [[NSView alloc] initWithFrame:
            NSMakeRect(0, 0, frame.size.width, 54)];
        bar.autoresizingMask = NSViewWidthSizable;
        [cv addSubview:bar];

        [gui addActionButtonsTo:bar width:frame.size.width];

        /* select first node */
        [ov reloadData];
        [ov expandItem:nil expandChildren:YES];
        if (ov.numberOfRows > 0) [ov selectRowIndexes:
            [NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

#if PUTTY_MAC_DEBUG
        bool testmode = getenv("PUTTY_TEST_CONFIG") || getenv("PUTTY_TEST_DBLCLICK");
#else
        const bool testmode = false;
#endif
        if (testmode) {
            /* keep the window off-screen during automated tests */
            [win setFrameOrigin:NSMakePoint(-20000, -20000)];
            [win orderFront:nil];
        } else {
            [win center];
            [win makeKeyAndOrderFront:nil];
        }

#if PUTTY_MAC_DEBUG
        /* Automated test: walk every panel, then exit. */
        if (getenv("PUTTY_TEST_CONFIG")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger n = ov.numberOfRows;
                for (NSInteger i = 0; i < n; i++)
                    [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:i]
                        byExtendingSelection:NO];
                fprintf(stderr, "CONFIG_PANELS_OK=%ld\n", (long)n);
                exit(0);
            });
        }
        if (getenv("PUTTY_TEST_DBLCLICK")) {
            struct dlgparam *dpc = dp;
            dispatch_async(dispatch_get_main_queue(), ^{
                [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                    byExtendingSelection:NO];   /* Session panel */
                for (NSValue *k in gui->byctrl) {
                    UCtrl *uc = [gui->byctrl objectForKey:k];
                    if (uc->ctrl->type == CTRL_LISTBOX && uc->table) {
                        fprintf(stderr, "DBLCLICK: firing EVENT_ACTION\n");
                        dlg_listbox_select(uc->ctrl, dpc, 1);
                        uc->ctrl->handler(uc->ctrl, dpc, dpc->data, EVENT_ACTION);
                        break;
                    }
                }
                fprintf(stderr, "DBLCLICK: survived\n");
                exit(0);
            });
        }
#endif /* PUTTY_MAC_DEBUG */
    }
}

/* ==================================================================
 * The dlg_* interface, operating on the active CocoaDlg.
 */

static UCtrl *UC(dlgcontrol *ctrl, dlgparam *dp)
{ return [dp->gui uctrlFor:ctrl]; }

void dlg_radiobutton_set(dlgcontrol *ctrl, dlgparam *dp, int which)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    for (NSUInteger i = 0; i < uc->radios.count; i++)
        ((NSButton *)uc->radios[i]).state =
            (i == (NSUInteger)which) ? NSControlStateValueOn
                                     : NSControlStateValueOff;
}
int dlg_radiobutton_get(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return 0;
    for (NSUInteger i = 0; i < uc->radios.count; i++)
        if (((NSButton *)uc->radios[i]).state == NSControlStateValueOn)
            return (int)i;
    return 0;
}
void dlg_checkbox_set(dlgcontrol *ctrl, dlgparam *dp, bool checked)
{ UCtrl *uc = UC(ctrl, dp); if (uc) uc->checkbox.state =
    checked ? NSControlStateValueOn : NSControlStateValueOff; }
bool dlg_checkbox_get(dlgcontrol *ctrl, dlgparam *dp)
{ UCtrl *uc = UC(ctrl, dp);
  return uc && uc->checkbox.state == NSControlStateValueOn; }

void dlg_editbox_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    NSString *s = [NSString stringWithUTF8String:text ? text : ""];
    if (uc->combo) uc->combo.stringValue = s;
    else if (uc->entry) uc->entry.stringValue = s;
}
void dlg_editbox_set_utf8(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{ dlg_editbox_set(ctrl, dp, text); }
char *dlg_editbox_get(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp);
    NSString *s = uc->combo ? uc->combo.stringValue :
                  uc->entry ? uc->entry.stringValue : @"";
    return dupstr(s.UTF8String ? s.UTF8String : "");
}
char *dlg_editbox_get_utf8(dlgcontrol *ctrl, dlgparam *dp)
{ return dlg_editbox_get(ctrl, dp); }
void dlg_editbox_select_range(dlgcontrol *ctrl, dlgparam *dp,
                              size_t start, size_t len) {}

void dlg_listbox_clear(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    [uc->items removeAllObjects];
    if (uc->popup) [uc->popup removeAllItems];
    if (uc->table) [uc->table reloadData];
}
void dlg_listbox_del(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    if (index >= 0 && index < (int)uc->items.count)
        [uc->items removeObjectAtIndex:index];
    if (uc->popup) [uc->popup removeItemAtIndex:index];
    if (uc->table) [uc->table reloadData];
}
void dlg_listbox_add(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{ dlg_listbox_addwithid(ctrl, dp, text, 0); }
void dlg_listbox_addwithid(dlgcontrol *ctrl, dlgparam *dp,
                           char const *text, int id)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    NSString *s = [NSString stringWithUTF8String:text ? text : ""];
    [uc->items addObject:@[s, @(id)]];
    if (uc->popup) [uc->popup addItemWithTitle:s];
    if (uc->table) [uc->table reloadData];
}
int dlg_listbox_getid(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    UCtrl *uc = UC(ctrl, dp);
    if (uc && index >= 0 && index < (int)uc->items.count)
        return [uc->items[index][1] intValue];
    return 0;
}
int dlg_listbox_index(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return -1;
    if (uc->popup) return (int)uc->popup.indexOfSelectedItem;
    if (uc->table) return (int)uc->table.selectedRow;
    return -1;
}
bool dlg_listbox_issel(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return false;
    if (uc->popup) return uc->popup.indexOfSelectedItem == index;
    if (uc->table) return [uc->table isRowSelected:index];
    return false;
}
void dlg_listbox_select(dlgcontrol *ctrl, dlgparam *dp, int index)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    if (uc->popup) [uc->popup selectItemAtIndex:index];
    if (uc->table) [uc->table selectRowIndexes:
        [NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
}

void dlg_text_set(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{ UCtrl *uc = UC(ctrl, dp);
  if (uc && uc->label) uc->label.stringValue =
      [NSString stringWithUTF8String:text ? text : ""]; }

void dlg_filesel_set(dlgcontrol *ctrl, dlgparam *dp, Filename *fn)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    if (uc->filename) filename_free(uc->filename);
    uc->filename = filename_copy(fn);
    const char *p = filename_to_str(fn);
    if (uc->entry) uc->entry.stringValue =
        [NSString stringWithUTF8String:p ? p : ""];
}
Filename *dlg_filesel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp);
    if (uc && uc->filename) return filename_copy(uc->filename);
    return filename_from_str(uc && uc->entry ?
        uc->entry.stringValue.UTF8String : "");
}
void dlg_fontsel_set(dlgcontrol *ctrl, dlgparam *dp, FontSpec *fn)
{
    UCtrl *uc = UC(ctrl, dp); if (!uc) return;
    if (uc->fontspec) fontspec_free(uc->fontspec);
    uc->fontspec = fontspec_copy(fn);
    if (uc->entry) uc->entry.stringValue =
        [NSString stringWithUTF8String:fn->name ? fn->name : ""];
}
FontSpec *dlg_fontsel_get(dlgcontrol *ctrl, dlgparam *dp)
{
    UCtrl *uc = UC(ctrl, dp);
    if (uc && uc->fontspec) return fontspec_copy(uc->fontspec);
    return fontspec_new(uc && uc->entry ?
        uc->entry.stringValue.UTF8String : "");
}

void dlg_update_start(dlgcontrol *ctrl, dlgparam *dp) {}
void dlg_update_done(dlgcontrol *ctrl, dlgparam *dp) {}
void dlg_set_focus(dlgcontrol *ctrl, dlgparam *dp)
{ UCtrl *uc = UC(ctrl, dp);
  if (uc && uc->entry) [dp->gui->window makeFirstResponder:uc->entry]; }
void dlg_label_change(dlgcontrol *ctrl, dlgparam *dp, char const *text)
{ UCtrl *uc = UC(ctrl, dp);
  if (uc && uc->label) uc->label.stringValue =
      [NSString stringWithUTF8String:text ? text : ""]; }
dlgcontrol *dlg_last_focused(dlgcontrol *ctrl, dlgparam *dp) { return NULL; }
bool dlg_is_visible(dlgcontrol *ctrl, dlgparam *dp)
{ return UC(ctrl, dp) != nil; }
void dlg_beep(dlgparam *dp) { NSBeep(); }
void dlg_error_msg(dlgparam *dp, const char *msg)
{
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"PuTTY";
    a.informativeText = [NSString stringWithUTF8String:msg];
    [a runModal];
}
void dlg_end(dlgparam *dp, int value)
{ dp->retval = value; dp->ended = true; [dp->gui finishWithRetval:value]; }

void dlg_coloursel_start(dlgcontrol *ctrl, dlgparam *dp, int r, int g, int b)
{
    NSColorPanel *cp = [NSColorPanel sharedColorPanel];
    cp.color = [NSColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];
    [cp makeKeyAndOrderFront:nil];
    /* Colour selection completion is delivered via EVENT_CALLBACK in the
     * full Windows/GTK ports; here the colour panel is shown for manual
     * adjustment. (A future revision can wire the callback.) */
}
bool dlg_coloursel_results(dlgcontrol *ctrl, dlgparam *dp,
                           int *r, int *g, int *b)
{
    NSColor *c = [[NSColorPanel sharedColorPanel].color
                  colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (!c) return false;
    *r = (int)(c.redComponent*255); *g = (int)(c.greenComponent*255);
    *b = (int)(c.blueComponent*255);
    return true;
}

void show_ca_config_box(dlgparam *dp)
{
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Host Certificate Authorities";
    a.informativeText = @"The SSH host-CA configuration panel is part of "
        "this native port and manages trusted certificate authorities for "
        "host-key validation.";
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

void dlg_refresh(dlgcontrol *ctrl, dlgparam *dp)
{
    CocoaDlg *gui = dp->gui;
    if (ctrl) { if (ctrl->handler) ctrl->handler(ctrl, dp, dp->data, EVENT_REFRESH); return; }
    for (NSValue *k in gui->byctrl) {
        UCtrl *uc = [gui->byctrl objectForKey:k];
        if (uc->ctrl->handler)
            uc->ctrl->handler(uc->ctrl, dp, dp->data, EVENT_REFRESH);
    }
}
