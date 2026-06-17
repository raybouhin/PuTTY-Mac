/*
 * cocoa-eventloop.m: integrate PuTTY's portable event model with the
 * macOS CoreFoundation run loop.
 *
 * PuTTY's core expects the front end to provide three things:
 *
 *   1. uxsel_input_add/remove  - watch a file descriptor for
 *      read/write readiness and call select_result() when ready.
 *
 *   2. timer_change_notify     - arrange for run_timers() to be called
 *      at a given absolute time.
 *
 *   3. a toplevel-callback notification hook - so that queued
 *      "run later" callbacks actually get run from the main loop.
 *
 * Everything below wires those onto CFRunLoop primitives so that the
 * portable networking (unix/network.c, unix/fd-socket.c) and terminal
 * scheduling work unchanged, driven by the same run loop AppKit uses.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>

#include "cocoa-platform.h"

/*
 * The opaque type uxsel_input_add() returns. The core never looks
 * inside it; it only hands it back to uxsel_input_remove().
 */
struct uxsel_id {
    int fd;
    CFFileDescriptorRef cffd;
    CFRunLoopSourceRef source;
    int rwx;
};

/* Forward decls. */
static void osx_run_callbacks_and_reschedule(void);
void notify_toplevel_callback(void *ignored);

/* ------------------------------------------------------------------
 * File-descriptor watching.
 */

static void osx_fd_callback(CFFileDescriptorRef cffd,
                            CFOptionFlags callBackTypes, void *info)
{
    struct uxsel_id *id = (struct uxsel_id *)info;
    int fd = CFFileDescriptorGetNativeDescriptor(cffd);

    /*
     * Translate the CF callback types into PuTTY's SELECT_* bits and
     * deliver them. PuTTY wants exception, then read, then write.
     */
    if (callBackTypes & kCFFileDescriptorReadCallBack)
        select_result(fd, SELECT_R);
    if (callBackTypes & kCFFileDescriptorWriteCallBack)
        select_result(fd, SELECT_W);

    /*
     * CFFileDescriptor callbacks are one-shot: we must re-enable the
     * ones we still care about. The fd may have been removed during
     * select_result(); guard against that by checking validity.
     */
    if (CFFileDescriptorIsValid(cffd)) {
        CFOptionFlags want = 0;
        if (id->rwx & SELECT_R) want |= kCFFileDescriptorReadCallBack;
        if (id->rwx & SELECT_W) want |= kCFFileDescriptorWriteCallBack;
        if (want)
            CFFileDescriptorEnableCallBacks(cffd, want);
    }

    /* Network activity may have queued deferred work. Run it now. */
    osx_run_callbacks_and_reschedule();
}

uxsel_id *uxsel_input_add(int fd, int rwx)
{
    struct uxsel_id *id = snew(struct uxsel_id);
    id->fd = fd;
    id->rwx = rwx;

    CFFileDescriptorContext ctx = { 0, id, NULL, NULL, NULL };
    id->cffd = CFFileDescriptorCreate(kCFAllocatorDefault, fd, false,
                                      osx_fd_callback, &ctx);

    CFOptionFlags want = 0;
    if (rwx & SELECT_R) want |= kCFFileDescriptorReadCallBack;
    if (rwx & SELECT_W) want |= kCFFileDescriptorWriteCallBack;
    if (want)
        CFFileDescriptorEnableCallBacks(id->cffd, want);

    id->source = CFFileDescriptorCreateRunLoopSource(
        kCFAllocatorDefault, id->cffd, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), id->source,
                       kCFRunLoopCommonModes);
    return id;
}

void uxsel_input_remove(uxsel_id *id)
{
    if (!id)
        return;
    if (id->source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), id->source,
                              kCFRunLoopCommonModes);
        CFRelease(id->source);
    }
    if (id->cffd) {
        CFFileDescriptorInvalidate(id->cffd);
        CFRelease(id->cffd);
    }
    sfree(id);
}

/* ------------------------------------------------------------------
 * Timers.
 */

static CFRunLoopTimerRef osx_timer = NULL;
static unsigned long osx_timer_next = 0;
static bool osx_timer_active = false;

static void osx_timer_fired(CFRunLoopTimerRef timer, void *info)
{
    unsigned long now = osx_timer_next;
    unsigned long next;

    osx_timer_active = false;

    if (run_timers(now, &next)) {
        /* run_timers may itself have re-armed us via timer_change_notify;
         * only schedule if it didn't. */
        if (!osx_timer_active)
            timer_change_notify(next);
    }

    osx_run_callbacks_and_reschedule();
}

void timer_change_notify(unsigned long next)
{
    long ticks = next - GETTICKCOUNT();
    if (ticks < 0)
        ticks = 0;

    osx_timer_next = next;
    osx_timer_active = true;

    /*
     * A CFRunLoopTimer created with interval 0 is ONE-SHOT: once it
     * fires it becomes invalid, and CFRunLoopTimerSetNextFireDate on a
     * fired one-shot timer does nothing. Reusing it therefore meant only
     * the first PuTTY timer ever fired, freezing all timer-driven work
     * (screen-redraw cooldown, cursor blink, keepalives). So we always
     * invalidate any existing timer and create a fresh one.
     */
    if (osx_timer) {
        CFRunLoopTimerInvalidate(osx_timer);
        CFRelease(osx_timer);
        osx_timer = NULL;
    }
    osx_timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + ticks / 1000.0,
        0, 0, 0, osx_timer_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), osx_timer, kCFRunLoopCommonModes);
}

/* ------------------------------------------------------------------
 * Top-level callbacks. PuTTY queues "do this from the main loop"
 * callbacks; we get notified when the queue becomes non-empty and
 * schedule a zero-delay run-loop wakeup to drain them.
 */

static bool osx_callback_scheduled = false;

static void osx_drain_callbacks(void)
{
    while (run_toplevel_callbacks())
        /* keep running until the queue drains */;
}

static void osx_run_callbacks_and_reschedule(void)
{
    osx_drain_callbacks();
}

/* Run via a 0s timer so we return to the run loop between callbacks. */
static void osx_callback_timer_fired(CFRunLoopTimerRef t, void *info)
{
    osx_callback_scheduled = false;
    osx_drain_callbacks();
    if (toplevel_callback_pending())
        notify_toplevel_callback(NULL);
}

static void osx_schedule_callback_drain(void)
{
    if (osx_callback_scheduled)
        return;
    osx_callback_scheduled = true;
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0, 0, 0,
        osx_callback_timer_fired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    CFRelease(t);
}

void notify_toplevel_callback(void *ignored)
{
    osx_schedule_callback_drain();
}

/* ------------------------------------------------------------------
 * One-time setup.
 */

void osx_eventloop_setup(void)
{
    sk_init();
    uxsel_init();
    request_callback_notifications(notify_toplevel_callback, NULL);
}
