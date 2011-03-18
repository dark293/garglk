/******************************************************************************
 *                                                                            *
 * Copyright (C) 2010 by Ben Cressey.                                         *
 *                                                                            *
 * This file is part of Gargoyle.                                             *
 *                                                                            *
 * Gargoyle is free software; you can redistribute it and/or modify           *
 * it under the terms of the GNU General Public License as published by       *
 * the Free Software Foundation; either version 2 of the License, or          *
 * (at your option) any later version.                                        *
 *                                                                            *
 * Gargoyle is distributed in the hope that it will be useful,                *
 * but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 * GNU General Public License for more details.                               *
 *                                                                            *
 * You should have received a copy of the GNU General Public License          *
 * along with Gargoyle; if not, write to the Free Software                    *
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA *
 *                                                                            *
 *****************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <mach/mach_time.h>

#include "glk.h"
#include "garglk.h"

#import "Cocoa/Cocoa.h"

#ifdef __ppc__
#define ByteOrderUCS4 kCFStringEncodingUTF32
#else
#define ByteOrderUCS4 kCFStringEncodingUTF32LE
#endif

static volatile int gli_event_waiting = FALSE;
static volatile int gli_window_alive = TRUE;

#define kArrowCursor 1
#define kIBeamCursor 2
#define kPointingHandCursor 3

@protocol GargoyleApp
- (BOOL) initWindow: (pid_t) processID
              width: (unsigned int) width
             height: (unsigned int) height;

- (NSEvent *) getWindowEvent: (pid_t) processID;

- (NSRect) getWindowSize: (pid_t) processID;

- (NSString *) getWindowCharString: (pid_t) processID;

- (BOOL) clearWindowCharString: (pid_t) processID;

- (BOOL) setWindow: (pid_t) processID
        charString: (NSEvent *) event;

- (BOOL) setWindow: (pid_t) processID
             title: (NSString *) title;

- (BOOL) setWindow: (pid_t) processID
          contents: (NSData *) frame
             width: (unsigned int) width
            height: (unsigned int) height;

- (void) closeWindow: (pid_t) processID;

- (NSString *) openWindowDialog: (pid_t) processID
                         prompt: (NSString *) prompt
                         filter: (unsigned int) filter;

- (NSString *) saveWindowDialog: (pid_t) processID
                         prompt: (NSString *) prompt
                         filter: (unsigned int) filter;

- (void) abortWindowDialog: (pid_t) processID
                    prompt: (NSString *) prompt;

- (void) setCursor: (unsigned int) cursor;

@end

@interface GargoyleMonitor : NSObject
{
    NSRect size;
    NSDate * referenceDate;
    NSTimeInterval interval;
    int timerid;
    int timeouts;
    int clock;
}
- (id) init;
- (void) sleep;
- (void) tick;
- (void) track: (NSTimeInterval) seconds;
- (BOOL) timeout;
- (void) reset;
- (void) connectionDied: (NSNotification *) notice;
@end

@implementation GargoyleMonitor

- (id) init
{
    self = [super init];

    referenceDate = [[NSDate alloc] init];
    interval = 0;
    timerid = -1;
    timeouts = 0;

    return self;
}

- (void) sleep
{
    while (!timeouts && !gli_event_waiting)
        [self tick];
}

- (void) tick
{
    if (!gli_window_alive)
        exit(1);

    if (timerid != -1)
    {
        if ([referenceDate compare: [NSDate date]] == NSOrderedAscending)
        {
            timeouts++;
            [referenceDate release];
            referenceDate = [[NSDate alloc] initWithTimeIntervalSinceNow: interval];
        }
        else
        {
            [NSThread sleepUntilDate: referenceDate];
        }
    }
    else
    {
        [NSThread sleepUntilDate: [NSDate distantFuture]];
    }
}

- (void) track: (NSTimeInterval) seconds
{
    if (timerid != -1)
    {
        timerid = -1;
        timeouts = 0;
    }

    if (seconds)
    {
        timerid = 1;
        interval = seconds;
        [referenceDate release];
        referenceDate = [[NSDate alloc] initWithTimeIntervalSinceNow: interval];
    }
}

- (BOOL) timeout
{
    return (timeouts != 0);
}

- (void) reset
{
    timeouts = 0;
}

- (void) connectionDied: (NSNotification *) notice
{
    exit(1);
}

@end

static NSObject<GargoyleApp> * gargoyle = NULL;
static GargoyleMonitor * monitor = NULL;
static NSBitmapImageRep * framebuffer = NULL;
static NSString * cliptext = NULL;
static pid_t processID = 0;

static int gli_refresh_needed = TRUE;
static int gli_window_hidden = FALSE;

void glk_request_timer_events(glui32 millisecs)
{
    [monitor track: ((double) millisecs) / 1000];
}

void winabort(const char *fmt, ...)
{
    va_list ap;
    char buf[256];
    va_start(ap, fmt);
    vsprintf(buf, fmt, ap);
    va_end(ap);

    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    [gargoyle abortWindowDialog: processID
                         prompt: [NSString stringWithCString: buf encoding: NSASCIIStringEncoding]];
    [pool drain];

    exit(1);
}

void winexit(void)
{
    [gargoyle closeWindow: processID];
    exit(0);
}

void winopenfile(char *prompt, char *buf, int len, int filter)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];    

    NSString * fileref = [gargoyle openWindowDialog: processID
                                             prompt: [NSString stringWithCString: prompt encoding: NSASCIIStringEncoding]
                                             filter: filter];

    strcpy(buf, "");

    if (fileref)
    {
        int size = [fileref length];
        
        CFStringGetBytes((CFStringRef) fileref, CFRangeMake(0, size),
                         kCFStringEncodingASCII, 0, FALSE,
                         buf, len, NULL);

        int bounds = size < len ? size : len;
        buf[bounds] = '\0';
    }

    [pool drain];
}

void winsavefile(char *prompt, char *buf, int len, int filter)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSString * fileref = [gargoyle saveWindowDialog: processID
                                             prompt: [NSString stringWithCString: prompt encoding: NSASCIIStringEncoding]
                                             filter: filter];

    strcpy(buf, "");

    if (fileref)
    {
        int size = [fileref length];
        
        CFStringGetBytes((CFStringRef) fileref, CFRangeMake(0, size),
                         kCFStringEncodingASCII, 0, FALSE,
                         buf, len, NULL);
        
        int bounds = size < len ? size : len;
        buf[bounds] = '\0';
    }

    [pool drain];
}

void winclipstore(glui32 *text, int len)
{
    if (!len)
        return;

    if (cliptext) {
        [cliptext release];
        cliptext = NULL;
    }

    cliptext = (NSString *) CFStringCreateWithBytes(kCFAllocatorDefault,
                                                    (char *) text, (len * 4),
                                                    ByteOrderUCS4, FALSE);
}

void winclipsend(void)
{
    if (cliptext)
    {
        NSPasteboard * clipboard = [NSPasteboard generalPasteboard];
        [clipboard declareTypes: [NSArray arrayWithObject: NSStringPboardType] owner:nil];
        [clipboard setString: cliptext forType: NSStringPboardType];
    }
}

void winclipreceive(void)
{
    int i, len;
    glui32 ch;

    NSPasteboard * clipboard = [NSPasteboard generalPasteboard];

    if ([clipboard availableTypeFromArray: [NSArray arrayWithObject: NSStringPboardType]])
    {
        NSString * input = [clipboard stringForType: NSStringPboardType];
        if (input)
        {
            len = [input length];
            for (i=0; i < len; i++)
            {
                if (CFStringGetBytes((CFStringRef) input, CFRangeMake(i, 1),
                                     kCFStringEncodingUTF32, 0, FALSE,
                                     (char *) &ch, 4, NULL))
                {
                    switch (ch)
                    {
                        case '\0':
                            return;

                        case '\r':
                        case '\n':
                        case '\b':
                        case '\t':
                            break;

                        default:
                            gli_input_handle_key(ch);
                    }
                }
            }
        }
    }
}

void wintitle(void)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    char buf[256];

    if (strlen(gli_story_title))
        sprintf(buf, "%s", gli_story_title);
    else if (strlen(gli_story_name))
        sprintf(buf, "%s - %s", gli_story_name, gli_program_name);
    else
        sprintf(buf, "%s", gli_program_name);

    NSString * title = [NSString stringWithCString: buf encoding: NSASCIIStringEncoding];

    [gargoyle setWindow: processID
                  title: title];

    [pool drain];
}

void winresize(void)
{
    NSRect viewRect = [gargoyle getWindowSize: processID];

    if (gli_image_w == (unsigned int) viewRect.size.width
            && gli_image_h == (unsigned int) viewRect.size.height)
        return;

    gli_image_w = (unsigned int) viewRect.size.width;
    gli_image_h = (unsigned int) viewRect.size.height;
    gli_image_s = ((gli_image_w * 4 + 3) / 4) * 4;

    /* initialize offline bitmap store */
    if (gli_image_rgb)
        free(gli_image_rgb);

     gli_image_rgb = malloc(gli_image_s * gli_image_h);

    /* redraw window content */
    gli_resize_mask(gli_image_w, gli_image_h);
    gli_force_redraw = TRUE;
    gli_refresh_needed = TRUE;
    gli_windows_size_change();
}

void winhandler(int signal)
{
    if (signal == SIGUSR1)
        gli_event_waiting = TRUE;

    if (signal == SIGUSR2)
        gli_window_alive = FALSE;
}

void wininit(int *argc, char **argv)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    /* establish link to launcher */
    NSString * linkName = [NSString stringWithUTF8String: getenv("GargoyleApp")];
    NSConnection * link = [NSConnection connectionWithRegisteredName: linkName host: NULL];
    [link retain];

    /* monitor link for failure */
    monitor = [[GargoyleMonitor alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver: monitor
                                             selector: @selector(connectionDied:)
                                                 name: NSConnectionDidDieNotification
                                               object: link];

    /* attach to app controller */
    gargoyle = (NSObject<GargoyleApp> *)[link rootProxy];
    [gargoyle retain];

    /* prepare signal handler */
    signal(SIGUSR1, winhandler);
    signal(SIGUSR2, winhandler);

    processID = getpid();

    [pool drain];
}

void winopen(void)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    unsigned int defw = gli_wmarginx * 2 + gli_cellw * gli_cols;
    unsigned int defh = gli_wmarginy * 2 + gli_cellh * gli_rows;

    [gargoyle initWindow: processID
                   width: defw
                  height: defh];

    wintitle();
    winresize();

    [pool drain];
}

void winrepaint(int x0, int y0, int x1, int y1)
{
    gli_refresh_needed = TRUE;
}

void winrefresh(void)
{
    gli_windows_redraw();

    NSData * frame = [NSData dataWithBytesNoCopy: gli_image_rgb
                                          length: gli_image_s * gli_image_h
                                    freeWhenDone: NO];

    int refreshed = [gargoyle setWindow: processID
                               contents: frame
                                  width: gli_image_w
                                 height: gli_image_h];

    gli_refresh_needed = !refreshed;
}

#define NSKEY_LEFT      0x7b
#define NSKEY_RIGHT     0x7c
#define NSKEY_DOWN      0x7d
#define NSKEY_UP        0x7e

#define NSKEY_X         0x07
#define NSKEY_C         0x08
#define NSKEY_V         0x09

#define NSKEY_PGUP      0x74
#define NSKEY_PGDN      0x79
#define NSKEY_HOME      0x73
#define NSKEY_END       0x77
#define NSKEY_DEL       0x75
#define NSKEY_BACK      0x33
#define NSKEY_ESC       0x35

#define NSKEY_F1        0x7a
#define NSKEY_F2        0x78
#define NSKEY_F3        0x63
#define NSKEY_F4        0x76
#define NSKEY_F5        0x60
#define NSKEY_F6        0x61
#define NSKEY_F7        0x62
#define NSKEY_F8        0x64
#define NSKEY_F9        0x65
#define NSKEY_F10       0x6d
#define NSKEY_F11       0x67
#define NSKEY_F12       0x6f

void winkey(NSEvent *evt)
{
    /* queue a screen refresh */
    gli_refresh_needed = TRUE;

    /* check for arrow keys */
    if ([evt modifierFlags] & NSFunctionKeyMask)
    {
        /* modified keys for scrolling */
        if ([evt modifierFlags] & NSCommandKeyMask
            || [evt modifierFlags] & NSAlternateKeyMask
            || [evt modifierFlags] & NSControlKeyMask)
        {
            switch ([evt keyCode])
            {
                case NSKEY_LEFT  : gli_input_handle_key(keycode_Home);     return;
                case NSKEY_RIGHT : gli_input_handle_key(keycode_End);      return;
                case NSKEY_DOWN  : gli_input_handle_key(keycode_PageDown); return;
                case NSKEY_UP    : gli_input_handle_key(keycode_PageUp);   return;
                default: break;
            }
        }

        /* unmodified keys for line editing */
        else
        {
            switch ([evt keyCode])
            {
                case NSKEY_LEFT  : gli_input_handle_key(keycode_Left);  return;
                case NSKEY_RIGHT : gli_input_handle_key(keycode_Right); return;
                case NSKEY_DOWN  : gli_input_handle_key(keycode_Down);  return;
                case NSKEY_UP    : gli_input_handle_key(keycode_Up);    return;
                default: break;
            }
        }
    }

    /* check for menu commands */
    if ([evt modifierFlags] & NSCommandKeyMask)
    {
        switch ([evt keyCode])
        {
            case NSKEY_X:
            case NSKEY_C:
            {
                winclipsend();
                return;
            }

            case NSKEY_V:
            {
                winclipreceive();
                return;
            }

            default: break;
        }
    }

    /* check for command keys */
    switch ([evt keyCode])
    {
        case NSKEY_PGUP : gli_input_handle_key(keycode_PageUp);   return;
        case NSKEY_PGDN : gli_input_handle_key(keycode_PageDown); return;
        case NSKEY_HOME : gli_input_handle_key(keycode_Home);     return;
        case NSKEY_END  : gli_input_handle_key(keycode_End);      return;
        case NSKEY_DEL  : gli_input_handle_key(keycode_Erase);    return;
        case NSKEY_BACK : gli_input_handle_key(keycode_Delete);   return;
        case NSKEY_ESC  : gli_input_handle_key(keycode_Escape);   return;
        case NSKEY_F1   : gli_input_handle_key(keycode_Func1);    return;
        case NSKEY_F2   : gli_input_handle_key(keycode_Func2);    return;
        case NSKEY_F3   : gli_input_handle_key(keycode_Func3);    return;
        case NSKEY_F4   : gli_input_handle_key(keycode_Func4);    return;
        case NSKEY_F5   : gli_input_handle_key(keycode_Func5);    return;
        case NSKEY_F6   : gli_input_handle_key(keycode_Func6);    return;
        case NSKEY_F7   : gli_input_handle_key(keycode_Func7);    return;
        case NSKEY_F8   : gli_input_handle_key(keycode_Func8);    return;
        case NSKEY_F9   : gli_input_handle_key(keycode_Func9);    return;
        case NSKEY_F10  : gli_input_handle_key(keycode_Func10);   return;
        case NSKEY_F11  : gli_input_handle_key(keycode_Func11);   return;
        case NSKEY_F12  : gli_input_handle_key(keycode_Func12);   return;
        default: break;
    }

    /* send combined keystrokes to text buffer */
    [gargoyle setWindow: processID charString: evt];

    /* retrieve character from buffer as string */
    NSString * evt_char = [gargoyle getWindowCharString: processID];

    /* convert character to UTF-32 value */
    glui32 ch;
    if (CFStringGetBytes((CFStringRef) evt_char,
                         CFRangeMake(0, [evt_char length]),
                         kCFStringEncodingUTF32, 0, FALSE,
                         (char *)&ch, 4, NULL)) {
        switch (ch)
        {
            case '\n': gli_input_handle_key(keycode_Return); break;
            case '\t': gli_input_handle_key(keycode_Tab);    break;
            default: gli_input_handle_key(ch); break;
        }
    }

    /* discard contents of text buffer */
    [gargoyle clearWindowCharString: processID];
}

void winmouse(NSEvent *evt)
{
    NSPoint coords = [evt locationInWindow];

    int x = coords.x;
    int y = gli_image_h - coords.y;

    /* disregard most events outside of content window */
    if ((coords.y < 0 || y < 0 || x < 0 || x > gli_image_w)
        && !([evt type] == NSLeftMouseUp))
        return;

    switch ([evt type])
    {
        case NSLeftMouseDown:
        {
            gli_input_handle_click(x, y);
            [gargoyle setCursor: kArrowCursor];
            break;
        }

        case NSLeftMouseDragged:
        {
            if (gli_copyselect)
            {
                [gargoyle setCursor: kIBeamCursor];
                gli_move_selection(x, y);
            }
            break;
        }

        case NSMouseMoved:
        {
            if (gli_get_hyperlink(x, y))
                [gargoyle setCursor: kPointingHandCursor];
            else
                [gargoyle setCursor: kArrowCursor]; 
            break;
        }

        case NSLeftMouseUp:
        {
            gli_copyselect = FALSE;
            [gargoyle setCursor: kArrowCursor];
            break;
        }

        case NSScrollWheel:
        {
            if ([evt deltaY] > 0)
                gli_input_handle_key(keycode_MouseWheelUp);
            else if ([evt deltaY] < 0)
                gli_input_handle_key(keycode_MouseWheelDown);
            break;
        }

        default: break;
    }

}

void winevent(NSEvent *evt)
{
    if (!evt)
    {
        gli_event_waiting = FALSE;
        return;
    }

    switch ([evt type])
    {
        case NSKeyDown:
        {
            winkey(evt);
            return;
        }

        case NSLeftMouseDown:
        case NSLeftMouseDragged:
        case NSLeftMouseUp:
        case NSMouseMoved:
        case NSScrollWheel:
        {
            winmouse(evt);
            return;
        }

        case NSApplicationDefined:
        {
            gli_refresh_needed = TRUE;
            winresize();
            return;
        }

        default: return;
    }
}

/* winloop handles at most one event */
void winloop(void)
{
    NSEvent * evt = NULL;

    if (gli_refresh_needed)
        winrefresh();

    if (gli_event_waiting)
        evt = [gargoyle getWindowEvent: processID];

    winevent(evt);
}

/* winpoll handles all queued events */
void winpoll(void)
{
    NSEvent * evt = NULL;

    do
    {
        if (gli_refresh_needed)
            winrefresh();

        if (gli_event_waiting)
            evt = [gargoyle getWindowEvent: processID];

        winevent(evt);
    }
    while (evt);
}

void gli_select(event_t *event, int polled)
{ 
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    gli_curevent = event;
    gli_event_clearevent(event);

    winpoll();
    gli_dispatch_event(gli_curevent, polled);

    if (gli_curevent->type == evtype_None && !polled)
    {
        while (![monitor timeout])
        {
            winloop();
            gli_dispatch_event(gli_curevent, polled);

            if (gli_curevent->type == evtype_None)
                [monitor sleep];
            else
                break;
        }
    }

    if (gli_curevent->type == evtype_None && [monitor timeout])
    {
        gli_event_store(evtype_Timer, NULL, 0, 0);
        gli_dispatch_event(gli_curevent, polled);
        [monitor reset];
    }

    gli_curevent = NULL;

    [pool drain];
}

/* monotonic clock time for profiling */
void wincounter(glktimeval_t *time)
{
    static mach_timebase_info_data_t info = {0,0};
    if (!info.denom)
        mach_timebase_info(&info);

    uint64_t tick = mach_absolute_time();
    tick *= info.numer;
    tick /= info.denom;

    time->high_sec = 0;
    time->low_sec  = (unsigned int) tick / 1000000000;
    time->microsec = (unsigned int) tick / 1000;
}
