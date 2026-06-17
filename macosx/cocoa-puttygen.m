/*
 * cocoa-puttygen.m: native PuTTYgen key-generator window.
 *
 * Reuses PuTTY's portable key-generation backend (rsa_generate /
 * ecdsa_generate / eddsa_generate / dsa_generate) and key serialisers
 * (ppk_save_f, ssh2_pubkey_openssh_str), wrapped in a native AppKit
 * window. Mirrors the Windows PuTTYgen workflow: pick a key type and
 * size, Generate, set a passphrase, then save the private (.ppk) and
 * public (OpenSSH) keys.
 */

#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include <sys/random.h>

#include "cocoa-platform.h"
#include "ssh.h"
#include "sshkeygen.h"

enum { KT_RSA, KT_ECDSA, KT_ED25519, KT_DSA };

/* A no-op progress receiver (generation is fast enough not to need a bar
 * for typical key sizes; a future revision can animate one). */
static ProgressPhase pg_add_linear(ProgressReceiver *p, double c)
{ ProgressPhase ph = { 0 }; return ph; }
static ProgressPhase pg_add_probabilistic(ProgressReceiver *p, double c, double pr)
{ ProgressPhase ph = { 0 }; return ph; }
static void pg_start_phase(ProgressReceiver *p, ProgressPhase ph) {}
static void pg_report(ProgressReceiver *p, double pr) {}
static void pg_report_attempt(ProgressReceiver *p) {}
static void pg_report_phase_complete(ProgressReceiver *p) {}
static const ProgressReceiverVtable pg_vt = {
    .add_linear = pg_add_linear,
    .add_probabilistic = pg_add_probabilistic,
    .ready = null_progress_ready,
    .start_phase = pg_start_phase,
    .report = pg_report,
    .report_attempt = pg_report_attempt,
    .report_phase_complete = pg_report_phase_complete,
};
static ProgressReceiver pg_prog = { .vt = &pg_vt };

@interface PuTTYgenWindow : NSObject <NSWindowDelegate>
{
@public
    NSWindow *window;
    NSPopUpButton *typePopup;
    NSTextField *bitsField;
    NSTextField *passField, *passConfirm, *commentField;
    NSTextView *pubView;
    NSTextField *fpField;
    NSButton *genButton;
    BOOL busy;
    ssh2_userkey *key;
}
@end

@implementation PuTTYgenWindow

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    NSRect frame = NSMakeRect(0, 0, 620, 460);
    window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"PuTTYgen — Key Generator";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    NSView *cv = window.contentView;

    CGFloat top = frame.size.height;

    NSTextField *(^lab)(NSString*, CGFloat) = ^NSTextField*(NSString *s, CGFloat y){
        NSTextField *l = [NSTextField labelWithString:s];
        l.frame = NSMakeRect(16, y, 110, 22);
        l.alignment = NSTextAlignmentRight;
        [cv addSubview:l]; return l;
    };

    lab(@"Key type:", top-40);
    typePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(132, top-42, 220, 26)];
    [typePopup addItemsWithTitles:@[@"RSA", @"ECDSA", @"Ed25519", @"DSA"]];
    [typePopup setTarget:self];
    [typePopup setAction:@selector(typeChanged:)];
    [cv addSubview:typePopup];

    lab(@"Bits:", top-74);
    bitsField = [[NSTextField alloc] initWithFrame:NSMakeRect(132, top-76, 100, 24)];
    bitsField.stringValue = @"2048";
    [cv addSubview:bitsField];

    NSButton *gen = [NSButton buttonWithTitle:@"Generate"
        target:self action:@selector(generate:)];
    gen.bezelStyle = NSBezelStyleRounded;
    gen.frame = NSMakeRect(360, top-78, 110, 30);
    gen.keyEquivalent = @"\r";
    [cv addSubview:gen];
    genButton = gen;

    lab(@"Public key:", top-108);
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(132, top-220, 470, 108)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.verticalScroller.knobStyle = NSScrollerKnobStyleDark;
    pubView = [[NSTextView alloc] initWithFrame:sv.bounds];
    pubView.editable = NO;
    pubView.font = [NSFont fontWithName:@"Menlo" size:11];
    sv.documentView = pubView;
    [cv addSubview:sv];

    lab(@"Fingerprint:", top-248);
    fpField = [NSTextField labelWithString:@""];
    fpField.frame = NSMakeRect(132, top-250, 470, 22);
    fpField.font = [NSFont fontWithName:@"Menlo" size:11];
    [cv addSubview:fpField];

    lab(@"Comment:", top-282);
    commentField = [[NSTextField alloc] initWithFrame:NSMakeRect(132, top-284, 470, 24)];
    [cv addSubview:commentField];

    lab(@"Passphrase:", top-314);
    passField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(132, top-316, 250, 24)];
    [cv addSubview:passField];

    lab(@"Confirm:", top-346);
    passConfirm = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(132, top-348, 250, 24)];
    [cv addSubview:passConfirm];

    NSButton *savePriv = [NSButton buttonWithTitle:@"Save private key…"
        target:self action:@selector(savePrivate:)];
    savePriv.bezelStyle = NSBezelStyleRounded;
    savePriv.frame = NSMakeRect(132, 18, 180, 30);
    [cv addSubview:savePriv];

    NSButton *savePub = [NSButton buttonWithTitle:@"Save public key…"
        target:self action:@selector(savePublic:)];
    savePub.bezelStyle = NSBezelStyleRounded;
    savePub.frame = NSMakeRect(320, 18, 180, 30);
    [cv addSubview:savePub];

    [window center];
    [window makeKeyAndOrderFront:nil];
    return self;
}

- (void)typeChanged:(id)sender
{
    switch (typePopup.indexOfSelectedItem) {
      case KT_RSA: bitsField.stringValue = @"2048"; bitsField.enabled = YES; break;
      case KT_ECDSA: bitsField.stringValue = @"256"; bitsField.enabled = YES; break;
      case KT_ED25519: bitsField.stringValue = @"255"; bitsField.enabled = NO; break;
      case KT_DSA: bitsField.stringValue = @"2048"; bitsField.enabled = YES; break;
    }
}

- (void)generate:(id)sender
{
    if (busy) return;
    int type = (int)typePopup.indexOfSelectedItem;
    int bits = bitsField.intValue;
    if (bits <= 0) bits = 2048;

    /* Set up the PRNG once: random_setup_special() creates the global
     * generator and asserts it doesn't already exist, so calling it on a
     * second Generate would abort. After the first time we only reseed. */
    static bool prng_ready = false;
    if (!prng_ready) { random_setup_special(); prng_ready = true; }
    unsigned char ebuf[64];
    if (getentropy(ebuf, sizeof(ebuf)) != 0) {
        [self error:@"Could not gather entropy to generate a key."];
        return;
    }
    random_reseed(make_ptrlen(ebuf, sizeof(ebuf)));
    smemclr(ebuf, sizeof(ebuf));

    NSString *comment = commentField.stringValue.length ?
        commentField.stringValue :
        [NSString stringWithFormat:@"%@-key-%@",
            typePopup.titleOfSelectedItem, NSUserName()];

    /* Key generation (especially RSA/DSA prime search) is CPU heavy and
     * would otherwise block the UI. Run it on a background queue, then
     * apply the result on the main thread. This is safe here because the
     * PuTTYgen helper stubs out the timer subsystem (no-timing.c), so
     * nothing on the main thread touches the PRNG while we generate. */
    busy = YES;
    genButton.enabled = NO;
    fpField.stringValue = @"Generating, please wait…";
    pubView.string = @"";
    const char *commentC = dupstr(comment.UTF8String);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PrimeGenerationContext *pgc =
            primegen_new_context(&primegen_probabilistic);
        ssh2_userkey *k = snew(ssh2_userkey);
        k->comment = NULL;
        if (type == KT_RSA) {
            RSAKey *rk = snew(RSAKey);
            rsa_generate(rk, bits, false, pgc, &pg_prog);
            rk->comment = NULL; k->key = &rk->sshk;
        } else if (type == KT_ECDSA) {
            struct ecdsa_key *ek = snew(struct ecdsa_key);
            ecdsa_generate(ek, bits); k->key = &ek->sshk;
        } else if (type == KT_ED25519) {
            struct eddsa_key *ek = snew(struct eddsa_key);
            eddsa_generate(ek, 255); k->key = &ek->sshk;
        } else {
            struct dsa_key *dk = snew(struct dsa_key);
            dsa_generate(dk, bits, pgc, &pg_prog); k->key = &dk->sshk;
        }
        primegen_free_context(pgc);
        k->comment = (char *)commentC;

        char *pub = ssh2_pubkey_openssh_str(k);
        char *fp = ssh2_fingerprint(k->key, SSH_FPTYPE_SHA256);
        NSString *pubStr = [NSString stringWithUTF8String:pub];
        NSString *fpStr = [NSString stringWithUTF8String:fp];
        sfree(pub); sfree(fp);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (key) {
                if (key->key) ssh_key_free(key->key);
                sfree(key->comment);
                sfree(key);
            }
            key = k;
            commentField.stringValue = comment;
            pubView.string = pubStr;
            fpField.stringValue = fpStr;
            genButton.enabled = YES;
            busy = NO;
        });
    });
}

- (NSString *)checkedPassphrase
{
    if (![passField.stringValue isEqualToString:passConfirm.stringValue]) {
        [self error:@"The passphrase and its confirmation do not match."];
        return nil;
    }
    return passField.stringValue;
}

- (void)savePrivate:(id)sender
{
    if (!key) { [self error:@"Generate a key first."]; return; }
    NSString *pass = [self checkedPassphrase];
    if (!pass) return;
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"id_key.ppk";
    if ([p runModal] != NSModalResponseOK) return;
    Filename *fn = filename_from_str(p.URL.path.UTF8String);
    const char *pp = pass.length ? pass.UTF8String : NULL;
    bool ok = ppk_save_f(fn, key, pp, &ppk_save_default_parameters);
    filename_free(fn);
    if (!ok) [self error:@"Failed to save the private key."];
}

- (void)savePublic:(id)sender
{
    if (!key) { [self error:@"Generate a key first."]; return; }
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"id_key.pub";
    if ([p runModal] != NSModalResponseOK) return;
    char *pub = ssh2_pubkey_openssh_str(key);
    NSError *err = nil;
    [[NSString stringWithUTF8String:pub] writeToURL:p.URL atomically:YES
        encoding:NSUTF8StringEncoding error:&err];
    sfree(pub);
    if (err) [self error:@"Failed to save the public key."];
}

- (void)error:(NSString *)msg
{
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"PuTTYgen";
    a.informativeText = msg;
    [a runModal];
}

@end

static PuTTYgenWindow *g_puttygen;

void cocoa_open_puttygen(void)
{
    if (g_puttygen && g_puttygen->window) {
        [g_puttygen->window makeKeyAndOrderFront:nil];
        return;
    }
    g_puttygen = [[PuTTYgenWindow alloc] init];
}

/* ------------------------------------------------------------------
 * The PuTTYgen helper is its own process with its own main().
 */

@interface PuTTYgenAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation PuTTYgenAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n
{
#if PUTTY_MAC_DEBUG
    if (getenv("PUTTYGEN_TEST")) {
        /* Generate twice in one process, matching the fixed generate: flow
         * (PRNG set up once, reseeded each time). This must not assert on
         * the second pass. */
        bool prng_ready = false;
        for (int pass = 1; pass <= 2; pass++) {
            if (!prng_ready) { random_setup_special(); prng_ready = true; }
            unsigned char e[64]; getentropy(e, sizeof(e));
            random_reseed(make_ptrlen(e, sizeof(e)));
            struct eddsa_key *ek = snew(struct eddsa_key);
            eddsa_generate(ek, 255);
            ssh2_userkey k; k.key = &ek->sshk; k.comment = dupstr("test");
            char *pub = ssh2_pubkey_openssh_str(&k);
            fprintf(stderr, "GEN_OK pass %d pub=%.20s...\n", pass, pub);
            sfree(pub); ssh_key_free(k.key); sfree(k.comment);
        }
        fprintf(stderr, "GEN_TWICE_OK\n");
        exit(0);
    }
#endif
    [NSApp activateIgnoringOtherApps:YES]; cocoa_open_puttygen();
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a
{ return YES; }
@end

int main(int argc, char **argv)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        NSApp.appearance = nil;   /* follow the system light/dark theme */
        PuTTYgenAppDelegate *d = [[PuTTYgenAppDelegate alloc] init];
        NSApp.delegate = d;
        [NSApp run];
    }
    return 0;
}
