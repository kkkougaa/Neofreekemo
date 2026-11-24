//
//  ClickerMusic.x
//  NeoFreeBird
//

#import <MediaToolbox/MediaToolbox.h>
#import "Core/BHTSpotify.h"
#import "HookHelpers.h"

// MARK: - Clicker music
//
// The clicker character (Clicker.x) nods to music the way the desktop app does
// ({kind: 'beat', strength, interval} to the page), from two sources, neither of them the
// microphone:
//
// - Spotify: the header bubble already polls what is playing (HeaderBubble.x CheckSpotify).
//   Spotify no longer gives tempo to new apps, so the song's BPM is looked up on Deezer's
//   public API (title and artist are sent there) and beats are timed from Spotify's playback
//   position. The tempo is right; where the beat falls is a guess, since nothing says where
//   the song's first beat is.
// - X's own videos (experimental): an MTAudioProcessingTap on the AVPlayerItem measures the
//   loudness and nods on sudden rises. Apple's tap does not attach to HTTP Live Streaming,
//   which is how X sends most videos, so this works only for file-like ones; the counters in
//   the shake dump say which.

extern BOOL NFBClickerVisible(void);
extern void NFBClickerBeat(double strength, double interval);
extern void NFBClickerLog(NSString* line);

static NSString* const kMusicBeat = @"kemo_clicker_music_beat";
static NSString* const kVideoBeat = @"kemo_clicker_video_beat";
static NSString* const kBPMCache = @"kemo_clicker_bpm_cache";

// MARK: BPM lookup

static NSString* gTrackKey;    // "title|artist" now playing, nil when nothing
static double gBPM;            // the tempo the clock uses; kept from the last song until the new one is known
static double gFoundBPM;       // this song's own tempo, 0 while unknown
static NSString* gBPMStatus = @"-";
static NSUInteger gLookup;     // generation, so a late answer for an old song is dropped

// "Song (feat. X) - Remastered 2011" → "Song": Deezer matches the plain title better.
static NSString* PlainTitle(NSString* title) {
    NSString* t = title ?: @"";
    for (NSString* pattern in @[@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", @"\\s+-\\s+.*$"]) {
        t = [t stringByReplacingOccurrencesOfString:pattern
                                         withString:@""
                                            options:NSRegularExpressionSearch
                                              range:NSMakeRange(0, t.length)];
    }
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return t.length ? t : title;
}

static void GetJSON(NSString* url, void (^done)(id json)) {
    NSURL* u = [NSURL URLWithString:url];
    if (!u) {
        done(nil);
        return;
    }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:u];
    request.timeoutInterval = 10;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                         id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                                         dispatch_async(dispatch_get_main_queue(), ^{
                                             done(json);
                                         });
                                     }] resume];
}

static NSString* Query(NSString* q) {
    NSString* e = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    e = [e stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    e = [e stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return [NSString stringWithFormat:@"https://api.deezer.com/search?limit=5&q=%@", e];
}

// Tempo from audio: mono samples → frame energy (hop 256) → log energy → its rises (onset
// strength) → autocorrelation at every lag between 60 and 200 BPM, plus half weight at twice
// the lag, leaning gently toward 120 BPM. Checked against known songs on 30-second previews
// (aespa Supernova 120.2 for 120, NewJeans Ditto 136 for 134, YOASOBI Idol 166.7 for 166,
// Uptown Funk 114.8 for 115); slow ballads can come out at double time.
// How alike the onset curve is to itself shifted by lag frames (lag may be fractional).
static double OnsetCorrelation(const double* onset, size_t frames, double lag) {
    size_t l0 = (size_t)lag;
    double fr = lag - l0;
    if (l0 + 1 >= frames) {
        return 0;
    }
    double sum = 0;
    for (size_t i = 0; i + l0 + 1 < frames; i++) {
        sum += onset[i] * ((1 - fr) * onset[i + l0] + fr * onset[i + l0 + 1]);
    }
    return sum / (frames - l0);
}

static double TempoOf(const float* x, size_t n, double rate) {
    const size_t hop = 256;
    size_t frames = n / hop;
    if (frames < 200) {
        return 0;
    }
    double* onset = calloc(frames, sizeof(double));
    double previous = 0, mean = 0;
    for (size_t f = 0; f < frames; f++) {
        double e = 0;
        for (size_t i = f * hop; i < (f + 1) * hop; i++) {
            e += (double)x[i] * x[i];
        }
        double le = log1p(1000 * e);
        onset[f] = f == 0 ? 0 : MAX(0, le - previous);
        previous = le;
        mean += onset[f];
    }
    mean /= frames;
    for (size_t f = 0; f < frames; f++) {
        onset[f] -= mean;
    }
    double fps = rate / hop;
    double best = 0, bestScore = -INFINITY;
    for (int b10 = 600; b10 <= 2000; b10++) {
        double bpm = b10 / 10.0;
        double lag = fps * 60 / bpm;
        double weight = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2));
        double score = (OnsetCorrelation(onset, frames, lag) + 0.5 * OnsetCorrelation(onset, frames, 2 * lag)) * weight;
        if (score > bestScore) {
            bestScore = score;
            best = bpm;
        }
    }
    free(onset);
    return best;
}

// Decodes a short audio file to mono floats at 11025 Hz and measures its tempo.
static double TempoOfFile(NSURL* file) {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:file options:nil];
    AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) {
        return 0;
    }
    NSError* error = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader) {
        return 0;
    }
    const double rate = 11025;
    NSDictionary* settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(rate),
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsNonInterleaved: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };
    AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    [reader addOutput:output];
    if (![reader startReading]) {
        return 0;
    }
    NSMutableData* pcm = [NSMutableData data];
    CMSampleBufferRef sample;
    while ((sample = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
        if (length) {
            NSUInteger at = pcm.length;
            pcm.length += length;
            CMBlockBufferCopyDataBytes(block, 0, length, (char*)pcm.mutableBytes + at);
        }
        CFRelease(sample);
        if (pcm.length > 40 * rate * sizeof(float)) {
            break; // 40 seconds is plenty
        }
    }
    [reader cancelReading];
    return TempoOf(pcm.bytes, pcm.length / sizeof(float), rate);
}

// Deezer: the best-matching track's own BPM when it has one (often 0), else the tempo of its
// 30-second preview, measured here.
static void FindBPM(NSString* title, NSString* artist, NSUInteger generation, void (^done)(double bpm, NSString* how)) {
    NSString* plain = PlainTitle(title);
    GetJSON(Query([NSString stringWithFormat:@"%@ %@", artist ?: @"", plain]), ^(id json) {
        if (generation != gLookup) {
            return;
        }
        NSArray* data = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSDictionary* pick = nil;
        if ([data isKindOfClass:[NSArray class]]) {
            for (NSDictionary* d in data) {
                if (![d isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSString* t = [d[@"title"] description] ?: @"";
                // Prefer the plain recording over remixes and live versions.
                if (!pick || ([t caseInsensitiveCompare:plain] == NSOrderedSame &&
                              [[pick[@"title"] description] caseInsensitiveCompare:plain] != NSOrderedSame)) {
                    pick = d;
                }
            }
        }
        if (!pick) {
            done(0, @"not on Deezer");
            return;
        }
        GetJSON([NSString stringWithFormat:@"https://api.deezer.com/track/%@", pick[@"id"]], ^(id track) {
            if (generation != gLookup) {
                return;
            }
            double bpm = [track isKindOfClass:[NSDictionary class]] && [track[@"bpm"] respondsToSelector:@selector(doubleValue)]
                             ? [track[@"bpm"] doubleValue]
                             : 0;
            if (bpm >= 40 && bpm <= 260) {
                done(bpm, @"Deezer");
                return;
            }
            NSURL* preview = [NSURL URLWithString:[pick[@"preview"] description] ?: @""];
            if (!preview.scheme) {
                done(0, @"no preview");
                return;
            }
            [[[NSURLSession sharedSession]
                downloadTaskWithURL:preview
                  completionHandler:^(NSURL* location, NSURLResponse* response, NSError* error) {
                      double measured = 0;
                      if (location) {
                          NSURL* copy = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                              URLByAppendingPathComponent:@"nfb_clicker_preview.mp3"];
                          [[NSFileManager defaultManager] removeItemAtURL:copy error:nil];
                          if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:copy error:nil]) {
                              measured = TempoOfFile(copy);
                              [[NSFileManager defaultManager] removeItemAtURL:copy error:nil];
                          }
                      }
                      dispatch_async(dispatch_get_main_queue(), ^{
                          done(measured, measured > 0 ? @"measured" : @"preview unreadable");
                      });
                  }] resume];
        });
    });
}

static void LookUpBPM(NSString* title, NSString* artist);
static void LookUpBPM(NSString* title, NSString* artist) {
    NSString* key = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
    NSDictionary* cache = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kBPMCache];
    if ([cache[key] respondsToSelector:@selector(doubleValue)] && [cache[key] doubleValue] > 0) {
        gFoundBPM = gBPM = [cache[key] doubleValue];
        gBPMStatus = [NSString stringWithFormat:@"%.1f (cached)", gBPM];
        return;
    }
    // Until this song's tempo is known the character keeps the last song's (it used to stop).
    NSUInteger generation = ++gLookup;
    gFoundBPM = 0;
    gBPMStatus = gBPM > 0 ? [NSString stringWithFormat:@"looking up, keeping %.1f", gBPM] : @"looking up";
    FindBPM(title, artist, generation, ^(double bpm, NSString* how) {
        if (generation != gLookup) {
            return;
        }
        if (bpm > 0) {
            gFoundBPM = gBPM = bpm;
            gBPMStatus = [NSString stringWithFormat:@"%.1f (%@)", bpm, how];
        } else {
            gBPMStatus = gBPM > 0 ? [NSString stringWithFormat:@"%@, keeping %.1f", how, gBPM] : how;
        }
        NFBClickerLog([NSString stringWithFormat:@"bpm %@ — %@", gBPMStatus, key]);
        if (bpm <= 0) {
            // Not remembered: a hiccup (or a slow preview) gets one more try in 20 seconds.
            static NSMutableSet<NSString*>* retried;
            if (!retried) {
                retried = [NSMutableSet set];
            }
            if (![retried containsObject:key]) {
                [retried addObject:key];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if ([key isEqualToString:gTrackKey] && gFoundBPM <= 0) {
                        LookUpBPM(title, artist);
                    }
                });
            }
            return;
        }
        NSMutableDictionary* next = [([[NSUserDefaults standardUserDefaults] dictionaryForKey:kBPMCache] ?: @{}) mutableCopy];
        if (next.count > 300) {
            [next removeAllObjects];
        }
        next[key] = @(bpm);
        [[NSUserDefaults standardUserDefaults] setObject:next forKey:kBPMCache];
    });
}

// MARK: Beat clock

static dispatch_source_t gClock;
static long long gLastBeat = -1;
static NSUInteger gBeatsSent;

static void ClockTick(void) {
    BHTSpotify* spotify = [BHTSpotify shared];
    if (![BHTSettings boolForKey:kMusicBeat] || gBPM <= 0 || !gTrackKey || !spotify.lastIsPlaying ||
        !spotify.lastAnswerAt || !NFBClickerVisible()) {
        gLastBeat = -1;
        return;
    }
    // Where in the song we are now, from where it was at Spotify's last answer.
    NSTimeInterval at = spotify.lastProgress - [spotify.lastAnswerAt timeIntervalSinceNow];
    if (spotify.lastDuration > 0 && at > spotify.lastDuration + 2) {
        return; // the song ended and the next poll has not come yet
    }
    double interval = 60.0 / gBPM;
    long long beat = (long long)floor(at / interval);
    if (beat == gLastBeat) {
        return;
    }
    BOOL first = gLastBeat < 0;
    gLastBeat = beat;
    if (first) {
        return; // start on the next whole beat, not half way through one
    }
    gBeatsSent++;
    NFBClickerBeat(beat % 4 == 0 ? 1.0 : 0.65, interval);
}

static void StartClock(void) {
    if (gClock) {
        return;
    }
    gClock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gClock, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.02 * NSEC_PER_SEC),
                              (uint64_t)(0.005 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gClock, ^{
        ClockTick();
    });
    dispatch_resume(gClock);
}

static void StopClock(void) {
    if (gClock) {
        dispatch_source_cancel(gClock);
        gClock = nil;
    }
    gLastBeat = -1;
}

// From HeaderBubble.x after each Spotify poll; nil title = nothing playing.
void NFBClickerMusicUpdate(NSString* title, NSString* artist) {
    if (title.length == 0) {
        gTrackKey = nil;
        StopClock();
        return;
    }
    NSString* key = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
    if (![key isEqualToString:gTrackKey]) {
        gTrackKey = key;
        gLastBeat = -1;
        if ([BHTSettings boolForKey:kMusicBeat]) {
            LookUpBPM(title, artist);
        }
    }
    if ([BHTSettings boolForKey:kMusicBeat] && [BHTSpotify shared].lastIsPlaying) {
        StartClock();
    } else {
        StopClock();
    }
}

// MARK: X video audio (experimental)

static NSUInteger gVideoItems, gVideoStreams, gVideoNoAudio, gVideoTapped, gVideoSkipped;
static volatile NSUInteger gVideoBuffers, gVideoBeats;

@interface NFBClickerTapBox : NSObject {
   @public
    double average;
    double lastBeat;
    double lastInterval;
    BOOL floatSamples;
    BOOL interleaved;
    UInt32 bytesPerSample;
}
@property (nonatomic, weak) AVPlayer* player;
@end

@implementation NFBClickerTapBox
@end

static void TapInit(MTAudioProcessingTapRef tap, void* clientInfo, void** storage) {
    *storage = clientInfo; // retained by the creator, released in TapFinalize
}

static void TapFinalize(MTAudioProcessingTapRef tap) {
    void* storage = MTAudioProcessingTapGetStorage(tap);
    if (storage) {
        CFRelease(storage);
    }
}

static void TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription* format) {
    NFBClickerTapBox* box = (__bridge NFBClickerTapBox*)MTAudioProcessingTapGetStorage(tap);
    box->floatSamples = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    box->interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    box->bytesPerSample = format->mBitsPerChannel / 8;
}

static void TapUnprepare(MTAudioProcessingTapRef tap) {
}

// Loudness per buffer against a slow running average; a sudden rise is a beat.
static void TapProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                       AudioBufferList* buffers, CMItemCount* framesOut, MTAudioProcessingTapFlags* flagsOut) {
    if (MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, NULL, framesOut) != noErr) {
        return;
    }
    NFBClickerTapBox* box = (__bridge NFBClickerTapBox*)MTAudioProcessingTapGetStorage(tap);
    AVPlayer* player = box.player;
    if (!player || player.muted || player.volume <= 0.01) {
        return; // muted autoplay in the timeline does not count
    }
    gVideoBuffers++;
    double sum = 0;
    UInt64 count = 0;
    for (UInt32 b = 0; b < buffers->mNumberBuffers; b++) {
        AudioBuffer buffer = buffers->mBuffers[b];
        if (box->floatSamples && box->bytesPerSample == 4) {
            const float* s = buffer.mData;
            UInt32 n = buffer.mDataByteSize / 4;
            for (UInt32 i = 0; i < n; i++) {
                sum += (double)s[i] * s[i];
            }
            count += n;
        } else if (box->bytesPerSample == 2) {
            const SInt16* s = buffer.mData;
            UInt32 n = buffer.mDataByteSize / 2;
            for (UInt32 i = 0; i < n; i++) {
                double v = s[i] / 32768.0;
                sum += v * v;
            }
            count += n;
        }
    }
    if (count == 0) {
        return;
    }
    double rms = sqrt(sum / count);
    double now = CACurrentMediaTime();
    double avg = box->average <= 0 ? rms : box->average;
    box->average = avg * 0.97 + rms * 0.03;
    if (rms > 0.02 && rms > avg * 1.45 && now - box->lastBeat > 0.22) {
        double gap = now - box->lastBeat;
        if (gap < 1.5) {
            box->lastInterval = box->lastInterval > 0 ? box->lastInterval * 0.7 + gap * 0.3 : gap;
        }
        box->lastBeat = now;
        double strength = MIN(1.0, (rms / avg - 1.0));
        double interval = box->lastInterval > 0 ? box->lastInterval : 0.5;
        gVideoBeats++;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([BHTSettings boolForKey:kVideoBeat]) {
                NFBClickerBeat(strength, interval);
            }
        });
    }
}

static void AttachTap(AVPlayer* player, AVPlayerItem* item) {
    if (!item || ![BHTSettings boolForKey:kVideoBeat] || objc_getAssociatedObject(item, @selector(AttachTap))) {
        return;
    }
    objc_setAssociatedObject(item, @selector(AttachTap), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gVideoItems++;
    if (item.audioMix) {
        gVideoSkipped++; // X set its own mix; leave it alone
        return;
    }
    AVAsset* asset = item.asset;
    NSURL* url = [asset isKindOfClass:[AVURLAsset class]] ? ((AVURLAsset*)asset).URL : nil;
    if ([url.pathExtension.lowercaseString isEqualToString:@"m3u8"]) {
        gVideoStreams++; // HLS: Apple's tap does not attach
        return;
    }
    __weak AVPlayer* weakPlayer = player;
    __weak AVPlayerItem* weakItem = item;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"]
                         completionHandler:^{
                             AVAssetTrack* track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
                             dispatch_async(dispatch_get_main_queue(), ^{
                                 AVPlayerItem* strongItem = weakItem;
                                 if (!strongItem) {
                                     return;
                                 }
                                 if (!track) {
                                     gVideoNoAudio++;
                                     return;
                                 }
                                 NFBClickerTapBox* box = [NFBClickerTapBox new];
                                 box.player = weakPlayer;
                                 MTAudioProcessingTapCallbacks callbacks = {
                                     .version = kMTAudioProcessingTapCallbacksVersion_0,
                                     .clientInfo = (void*)CFBridgingRetain(box),
                                     .init = TapInit,
                                     .finalize = TapFinalize,
                                     .prepare = TapPrepare,
                                     .unprepare = TapUnprepare,
                                     .process = TapProcess,
                                 };
                                 MTAudioProcessingTapRef tap = NULL;
                                 if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                                kMTAudioProcessingTapCreationFlag_PostEffects,
                                                                &tap) != noErr ||
                                     !tap) {
                                     CFRelease(callbacks.clientInfo);
                                     return;
                                 }
                                 AVMutableAudioMixInputParameters* params =
                                     [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
                                 params.audioTapProcessor = tap;
                                 CFRelease(tap);
                                 AVMutableAudioMix* mix = [AVMutableAudioMix audioMix];
                                 mix.inputParameters = @[params];
                                 strongItem.audioMix = mix;
                                 gVideoTapped++;
                             });
                         }];
}

%hook AVPlayer

- (instancetype)initWithPlayerItem:(AVPlayerItem*)item {
    AVPlayer* player = %orig;
    AttachTap(player, item);
    return player;
}

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem*)item {
    %orig;
    AttachTap(self, item);
}

%end

%hook AVQueuePlayer

- (void)insertItem:(AVPlayerItem*)item afterItem:(AVPlayerItem*)after {
    %orig;
    AttachTap(self, item);
}

%end

NSString* NFBClickerMusicDebugText(void) {
    BHTSpotify* s = [BHTSpotify shared];
    return [NSString stringWithFormat:@"spotify: beat=%d track=%@ playing=%d progress=%.1f/%.1f bpm=%@ clock=%d beats=%lu%c"
                                      @"video: on=%d items=%lu hls=%lu noAudio=%lu ownMix=%lu tapped=%lu buffers=%lu beats=%lu",
                                      [BHTSettings boolForKey:kMusicBeat], gTrackKey ?: @"-", s.lastIsPlaying,
                                      s.lastProgress, s.lastDuration, gBPMStatus, gClock != nil,
                                      (unsigned long)gBeatsSent, 10, [BHTSettings boolForKey:kVideoBeat],
                                      (unsigned long)gVideoItems, (unsigned long)gVideoStreams,
                                      (unsigned long)gVideoNoAudio, (unsigned long)gVideoSkipped,
                                      (unsigned long)gVideoTapped, (unsigned long)gVideoBuffers,
                                      (unsigned long)gVideoBeats];
}

%ctor {
    %init;
}
