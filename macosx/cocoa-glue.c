/*
 * cocoa-glue.c: small platform-glue functions that PuTTY's portable
 * and unix-POSIX cores expect the front end to provide. On the GTK
 * port these live in unix/putty.c and unix/window.c; here we provide
 * native equivalents (the message-box ones are overridden by nicer
 * AppKit versions in cocoa-main.m when the app is running).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include "putty.h"
#include "ssh.h"
#include "storage.h"

/*
 * pty.c is not linked into the GUI; provide the stubs it would
 * otherwise define so that anything referencing them still links.
 */
const bool use_pty_argv = false;
char **pty_argv = NULL;
char *pty_osx_envrestore_prefix = NULL;

/*
 * Feature flags consulted by the (portable) command-line and session
 * machinery.
 */
const bool use_event_log = true, new_session = true, saved_sessions = true;
const bool dup_check_launchable = true;
const bool share_can_be_downstream = true;
const bool share_can_be_upstream = true;

const unsigned cmdline_tooltype =
    TOOLTYPE_HOST_ARG |
    TOOLTYPE_PORT_ARG |
    TOOLTYPE_NO_VERBOSE_OPTION;

/* ------------------------------------------------------------------
 * Platform default settings. These mirror unix/window.c but with
 * macOS-appropriate choices (a Core Text font name, etc.).
 */

FontSpec *platform_default_fontspec(const char *name)
{
    if (!strcmp(name, "Font"))
        return fontspec_new("Menlo 12");
    else
        return fontspec_new_default();
}

Filename *platform_default_filename(const char *name)
{
    if (!strcmp(name, "LogFileName"))
        return filename_from_str("putty.log");
    else
        return filename_from_str("");
}

char *platform_default_s(const char *name)
{
    if (!strcmp(name, "SerialLine"))
        return dupstr("/dev/tty.usbserial");
    return NULL;
}

bool platform_default_b(const char *name, bool def)
{
    if (!strcmp(name, "WinNameAlways"))
        return false;
    return def;
}

int platform_default_i(const char *name, int def)
{
    if (!strcmp(name, "CloseOnExit"))
        return AUTO;                   /* close window iff clean exit */
    if (!strcmp(name, "MouseIsXterm"))
        return MOUSE_WINDOWS;          /* right-click pastes by default */
    return def;
}

/* ------------------------------------------------------------------
 * Backend selection.
 */

const struct BackendVtable *select_backend(Conf *conf)
{
    const struct BackendVtable *vt =
        backend_vt_from_proto(conf_get_int(conf, CONF_protocol));
    return vt;
}

/* ------------------------------------------------------------------
 * X11 display string (used by X11 forwarding). We don't ship an X
 * server, but honour $DISPLAY if the user has one (e.g. XQuartz).
 */

char *platform_get_x_display(void)
{
    const char *display = getenv("DISPLAY");
    return dupstr(display ? display : "");
}

/* ------------------------------------------------------------------
 * Fatal / non-fatal message boxes. Weakly defined here so that
 * cocoa-main.m can provide AppKit alert versions; if for some reason
 * those aren't present (e.g. a command-line invocation), we degrade to
 * stderr.
 */

void __attribute__((weak)) nonfatal(const char *fmt, ...)
{
    va_list ap;
    char *msg;
    va_start(ap, fmt);
    msg = dupvprintf(fmt, ap);
    va_end(ap);
    fprintf(stderr, "ERROR: %s\n", msg);
    sfree(msg);
}

void __attribute__((weak)) modalfatalbox(const char *fmt, ...)
{
    va_list ap;
    char *msg;
    va_start(ap, fmt);
    msg = dupvprintf(fmt, ap);
    va_end(ap);
    fprintf(stderr, "FATAL ERROR: %s\n", msg);
    sfree(msg);
    cleanup_exit(1);
}

/*
 * Front-end hooks referenced by the SSH key code and the X resource
 * lookup. We have no X resource database, and we surface the old-keyfile
 * warning through the normal non-fatal path.
 */
char *x_get_default(const char *key)
{
    return NULL;
}

void old_keyfile_warning(void)
{
    nonfatal("You are loading an SSH-2 private key in an old file format. "
             "Consider re-saving it with PuTTYgen in the current format.");
}

void cleanup_exit(int code)
{
    sk_cleanup();
    random_save_seed();
    exit(code);
}

/* ------------------------------------------------------------------
 * One-time portable setup: socket layer, default protocol/port.
 */

void setup(bool single)
{
    sk_init();
    enable_dit();
    settings_set_default_protocol(be_default_protocol);
    {
        const struct BackendVtable *vt =
            backend_vt_from_proto(be_default_protocol);
        settings_set_default_port(0);
        if (vt)
            settings_set_default_port(vt->default_port);
    }
}
