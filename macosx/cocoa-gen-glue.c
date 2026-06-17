/*
 * cocoa-gen-glue.c: minimal platform glue for the standalone PuTTYgen
 * helper executable. (The main app uses cocoa-glue.c; PuTTYgen must not
 * link the SSH-client glue, so it gets its own trimmed copy without any
 * backend/network references.)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include "putty.h"
#include "ssh.h"

FontSpec *platform_default_fontspec(const char *name)
{ return fontspec_new("Menlo 12"); }
Filename *platform_default_filename(const char *name)
{ return filename_from_str(""); }
char *platform_default_s(const char *name) { return NULL; }
bool platform_default_b(const char *name, bool def) { return def; }
int platform_default_i(const char *name, int def) { return def; }

char *x_get_default(const char *key) { return NULL; }

void old_keyfile_warning(void) { }

void nonfatal(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap); va_end(ap);
    fprintf(stderr, "ERROR: %s\n", msg);
    sfree(msg);
}

void modalfatalbox(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    char *msg = dupvprintf(fmt, ap); va_end(ap);
    fprintf(stderr, "FATAL: %s\n", msg);
    sfree(msg);
    cleanup_exit(1);
}

void cleanup_exit(int code) { exit(code); }
