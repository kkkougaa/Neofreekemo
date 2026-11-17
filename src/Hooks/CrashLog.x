//
//  CrashLog.x
//  NeoFreeBird
//

#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import "HookHelpers.h"

// MARK: - Last crash, for the debug dump
// Keeps the call stack of the most recent crash in Caches/nfb_last_crash.txt so it can
// be read back in the debug dump (volume down) after relaunching. Uncaught Objective-C
// exceptions write their reason and symbolicated stack; fatal signals write raw frames
// with backtrace_symbols_fd, which is safe inside a signal handler. The handlers that
// were installed before ours (Crashlytics) still run afterwards.

static char gCrashPath[1024];
static NSUncaughtExceptionHandler* gPreviousExceptionHandler = NULL;
static struct sigaction gPreviousActions[NSIG];
static const int kSignals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};

static NSString* NFBCrashPath(void) {
    NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"nfb_last_crash.txt"];
}

static void NFBWriteString(int fd, const char* text) {
    if (text) {
        write(fd, text, strlen(text));
    }
}

static void NFBSignalHandler(int sig, siginfo_t* info, void* context) {
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        NFBWriteString(fd, "signal ");
        NFBWriteString(fd, sig < NSIG ? sys_signame[sig] : "?");
        NFBWriteString(fd, "\n");
        void* frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }

    // Hand the signal to whoever had it before, or to the default action.
    struct sigaction* previous = &gPreviousActions[sig];
    if (previous->sa_flags & SA_SIGINFO) {
        if (previous->sa_sigaction) {
            previous->sa_sigaction(sig, info, context);
            return;
        }
    } else if (previous->sa_handler != SIG_DFL && previous->sa_handler != SIG_IGN &&
               previous->sa_handler != NULL) {
        previous->sa_handler(sig);
        return;
    }
    sigaction(sig, previous, NULL);
    raise(sig);
}

static void NFBExceptionHandler(NSException* exception) {
    NSString* text = [NSString stringWithFormat:@"exception %@: %@\n%@\n", exception.name,
                                                exception.reason,
                                                [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    [text writeToFile:NFBCrashPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
    if (gPreviousExceptionHandler) {
        gPreviousExceptionHandler(exception);
    }
}

static void NFBInstallCrashLog(void) {
    strlcpy(gCrashPath, NFBCrashPath().fileSystemRepresentation, sizeof(gCrashPath));

    gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&NFBExceptionHandler);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = NFBSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof(kSignals) / sizeof(kSignals[0]); i++) {
        sigaction(kSignals[i], &action, &gPreviousActions[kSignals[i]]);
    }
}

// Read by Hooks/DebugDump.x.
NSString* NFBLastCrashText(void) {
    NSString* path = NFBCrashPath();
    NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        return @"(none)";
    }
    NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate* date = attributes.fileModificationDate;
    NSString* header = [NSString stringWithFormat:@"at %@ (version at dump time: %s)", date, NFB_VERSION_STRING];
    if (text.length > 6000) {
        text = [text substringToIndex:6000];
    }
    return [NSString stringWithFormat:@"%@\n%@", header, text];
}

%ctor {
    // Crashlytics installs its handlers during launch; install ours after it so both run.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       NFBInstallCrashLog();
                   });
}
