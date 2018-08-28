//
//  SGPlayer.m
//  SGPlayer
//
//  Created by Single on 03/01/2017.
//  Copyright © 2017 single. All rights reserved.
//

#import "SGPlayer.h"
#import "SGMacro.h"
#import "SGActivity.h"
#import "SGSession.h"
#import "SGURLSource.h"
#import "SGConcatSource.h"
#import "SGAudioDecoder.h"
#import "SGVideoDecoder.h"
#import "SGAudioPlaybackOutput.h"
#import "SGVideoPlaybackOutput.h"

@interface SGPlayer ()

@property (nonatomic, strong, readonly) SGAsset * asset;
@property (nonatomic, strong, readonly) NSError * error;
@property (nonatomic, assign, readonly) SGPlaybackState state;
@property (nonatomic, assign, readonly) SGLoadingState loadingState;
@property (nonatomic, assign, readonly) CMTime time;
@property (nonatomic, assign, readonly) CMTime loadedTime;
@property (nonatomic, assign, readonly) CMTime duration;
@property (nonatomic, assign) CMTime rate;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) CMTime deviceDelay;
@property (nonatomic, strong) UIView * view;
@property (nonatomic, assign) SGScalingMode scalingMode;
@property (nonatomic, assign) SGDisplayMode displayMode;
@property (nonatomic, strong) SGVRViewport * viewport;
@property (nonatomic, copy) void (^displayCallback)(SGVideoFrame * frame);
@property (nonatomic, weak) id <SGPlayerDelegate> delegate;
@property (nonatomic, strong) NSOperationQueue * delegateQueue;

@end

@interface SGPlayer () <SGSessionDelegate>

@property (nonatomic, strong) NSLock * stateLock;
@property (nonatomic, strong) NSLock * loadingStateLock;
@property (nonatomic, strong) SGSession * session;
@property (nonatomic, strong) SGAudioPlaybackOutput * audioOutput;
@property (nonatomic, strong) SGVideoPlaybackOutput * videoOutput;
@property (nonatomic, assign) SGPlaybackState stateBeforSeeking;
@property (nonatomic, assign) CMTime lastTime;
@property (nonatomic, assign) CMTime lastLoadedTime;
@property (nonatomic, assign) CMTime lastDuration;

@end

@implementation SGPlayer

- (instancetype)init
{
    if (self = [super init])
    {
        self.stateLock = [[NSLock alloc] init];
        self.loadingStateLock = [[NSLock alloc] init];
        self.rate = CMTimeMake(1, 1);
        self.volume = 1.0;
        self.deviceDelay = CMTimeMake(1, 20);
        self.scalingMode = SGScalingModeResizeAspect;
        self.displayMode = SGDisplayModePlane;
        self.viewport = [[SGVRViewport alloc] init];
        self.delegateQueue = [NSOperationQueue mainQueue];
        [self destory];
    }
    return self;
}

- (void)dealloc
{
    [self destory];
}

#pragma mark - Asset

- (void)replaceWithURL:(NSURL *)URL
{
    [self replaceWithAsset:[[SGURLAsset alloc] initWithURL:URL]];
}

- (void)replaceWithAsset:(SGAsset *)asset
{
    [self stop];
    SGConcatAsset * concatAsset = [self concatAssetWithAsset:asset];
    if (!concatAsset)
    {
        return;
    }
    _asset = concatAsset;
    
    SGConcatSource * source = [[SGConcatSource alloc] initWithAsset:concatAsset];
    
    SGAudioDecoder * audioDecoder = [[SGAudioDecoder alloc] init];
    SGVideoDecoder * videoDecoder = [[SGVideoDecoder alloc] init];
    
    SGAudioPlaybackOutput * auidoOutput = [[SGAudioPlaybackOutput alloc] init];
    auidoOutput.timeSync = [[SGPlaybackTimeSync alloc] init];
    auidoOutput.rate = self.rate;
    auidoOutput.volume = self.volume;
    self.deviceDelay = self.deviceDelay;
    self.audioOutput = auidoOutput;
    
    SGVideoPlaybackOutput * videoOutput = [[SGVideoPlaybackOutput alloc] init];
    videoOutput.timeSync = self.audioOutput.timeSync;
    videoOutput.rate = self.rate;
    videoOutput.view = self.view;
    videoOutput.scalingMode = self.scalingMode;
    videoOutput.displayMode = self.displayMode;
    videoOutput.displayCallback = self.displayCallback;
    videoOutput.viewport = self.viewport;
    self.videoOutput = videoOutput;
    
    SGSessionConfiguration * configuration = [[SGSessionConfiguration alloc] init];
    configuration.source = source;
    configuration.audioDecoder = audioDecoder;
    configuration.videoDecoder = videoDecoder;
    configuration.audioOutput = auidoOutput;
    configuration.videoOutput = videoOutput;
    
    self.session = [[SGSession alloc] initWithConfiguration:configuration];
    self.session.delegate = self;
    [self.session open];
}

- (SGConcatAsset *)concatAssetWithAsset:(SGAsset *)asset
{
    if (!asset)
    {
        return nil;
    }
    SGConcatAsset * concatAsset = nil;
    if ([asset isKindOfClass:[SGURLAsset class]])
    {
        concatAsset = [[SGConcatAsset alloc] initWithAssets:@[(SGURLAsset *)asset]];
    }
    else if ([asset isKindOfClass:[SGConcatAsset class]])
    {
        concatAsset = (SGConcatAsset *)asset;
    }
    if (!concatAsset)
    {
        return nil;
    }
    BOOL error = NO;
    for (SGURLAsset * obj in concatAsset.assets)
    {
        if (!obj.URL)
        {
            error = YES;
            break;
        }
    }
    if (error)
    {
        return nil;
    }
    return concatAsset;
}

#pragma mark - State

- (SGBasicBlock)setState:(SGPlaybackState)state
{
    if (_state != state)
    {
        SGPlaybackState previousState = _state;
        _state = state;
        switch (_state)
        {
            case SGPlaybackStateSeeking:
                self.stateBeforSeeking = previousState;
                break;
            default:
                break;
        }
        return ^{
            [self playAndPause];
            [self callbackForTimingIfNeeded];
            [self callback:^{
                [self.delegate playerDidChangeState:self];
            }];
        };
    }
    return ^{};
}

- (SGBasicBlock)setLoadingState:(SGLoadingState)loadingState
{
    if (_loadingState != loadingState)
    {
        _loadingState = loadingState;
        return ^{
            [self playAndPause];
            [self callbackForTimingIfNeeded];
            [self callback:^{
                [self.delegate playerDidChangeLoadingState:self];
            }];
        };
    }
    return ^{};
}

#pragma mark - Timing

- (CMTime)time
{
    if (self.session.state == SGSessionStateFinished && self.session.empty)
    {
        return self.duration;
    }
    if (self.audioOutput.timeSync)
    {
        return self.audioOutput.timeSync.time;
    }
    return kCMTimeZero;
}

- (CMTime)loadedTime
{
    if (self.session.state == SGSessionStateFinished)
    {
        return self.duration;
    }
    CMTime time = self.time;
    CMTime loadedDuration = self.loadedDuration;
    CMTime duration = self.duration;
    CMTime loadedTime = CMTimeAdd(time, loadedDuration);
    return CMTimeMinimum(loadedTime, duration);
}

- (CMTime)duration
{
    if (self.session)
    {
        return self.session.duration;
    }
    return kCMTimeZero;
}

- (CMTime)loadedDuration
{
    if (self.session)
    {
        return self.session.loadedDuration;
    }
    return kCMTimeZero;
}

#pragma mark - Playback

- (void)setRate:(CMTime)rate
{
    if (CMTimeCompare(_rate, rate) != 0)
    {
        _rate = rate;
        self.audioOutput.rate = rate;
        self.videoOutput.rate = rate;
    }
}

- (void)play
{
    [SGActivity addTarget:self];
    [self.stateLock lock];
    switch (self.state)
    {
        case SGPlaybackStateFinished:
            if (self.session.state == SGSessionStateFinished && self.session.empty)
            {
                [self.session seekToTime:kCMTimeZero completionHandler:nil];
            }
            break;
        case SGPlaybackStateFailed:
            [self replaceWithAsset:self.asset];
            break;
        default:
            break;
    }
    SGBasicBlock callback = [self setState:SGPlaybackStatePlaying];
    [self.stateLock unlock];
    callback();
}

- (void)pause
{
    [SGActivity removeTarget:self];
    [self.stateLock lock];
    switch (self.state)
    {
        case SGPlaybackStateNone:
        case SGPlaybackStateFinished:
        case SGPlaybackStateFailed:
            [self.stateLock unlock];
            return;
        default:
            break;
    }
    SGBasicBlock callback = [self setState:SGPlaybackStatePaused];
    [self.stateLock unlock];
    callback();
}

- (void)stop
{
    [self destory];
    [self.stateLock lock];
    SGBasicBlock callback = [self setState:SGPlaybackStateNone];
    [self.stateLock unlock];
    [self.loadingStateLock lock];
    SGBasicBlock loadingStateCallback = [self setLoadingState:SGLoadingStateNone];
    [self.loadingStateLock unlock];
    callback();
    loadingStateCallback();
}

- (BOOL)seekable
{
    return self.session.seekable;
}

- (BOOL)seekableToTime:(CMTime)time
{
    return [self.session seekableToTime:time];
}

- (BOOL)seekToTime:(CMTime)time
{
    return [self seekToTime:time completionHandler:nil];
}

- (BOOL)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL, CMTime))completionHandler
{
    if (![self seekableToTime:time])
    {
        return NO;
    }
    [self.stateLock lock];
    if (self.state == SGPlaybackStateNone ||
        self.state == SGPlaybackStateFailed)
    {
        [self.stateLock unlock];
        return NO;
    }
    SGBasicBlock callback = [self setState:SGPlaybackStateSeeking];
    [self.stateLock unlock];
    callback();
    SGWeakSelf
    [self.session seekToTime:time completionHandler:^(BOOL success, CMTime time) {
        SGStrongSelf
        [self.stateLock lock];
        SGBasicBlock callback = [self setState:self.stateBeforSeeking];
        [self.stateLock unlock];
        callback();
        if (completionHandler)
        {
            [self callback:^{
                completionHandler(success, time);
            }];
        }
    }];
    return YES;
}

#pragma mark - Audio

- (void)setVolume:(float)volume
{
    if (_volume != volume)
    {
        _volume = volume;
        self.audioOutput.volume = _volume;
    }
}

- (void)setDeviceDelay:(CMTime)deviceDelay
{
    if (CMTimeCompare(_deviceDelay, deviceDelay) != 0)
    {
        _deviceDelay = deviceDelay;
        self.audioOutput.deviceDelay = deviceDelay;
    }
}

#pragma mark - Video

- (void)setView:(UIView *)view
{
    if (_view != view)
    {
        _view = view;
        self.videoOutput.view = _view;
    }
}

- (void)setScalingMode:(SGScalingMode)scalingMode
{
    if (_scalingMode != scalingMode)
    {
        _scalingMode = scalingMode;
        self.videoOutput.scalingMode = scalingMode;
    }
}

- (void)setDisplayMode:(SGDisplayMode)displayMode
{
    if (_displayMode != displayMode)
    {
        _displayMode = displayMode;
        self.videoOutput.displayMode = displayMode;
    }
}

- (void)setViewport:(SGVRViewport *)viewport
{
    if (_viewport != viewport)
    {
        _viewport = viewport;
        self.videoOutput.viewport = viewport;
    }
}

- (void)setDisplayCallback:(void (^)(SGVideoFrame *))displayCallback
{
    if (_displayCallback != displayCallback)
    {
        _displayCallback = displayCallback;
        self.videoOutput.displayCallback = displayCallback;
    }
}

- (UIImage *)originalImage
{
    return self.videoOutput.originalImage;
}

- (UIImage *)snapshot
{
    return self.videoOutput.snapshot;
}

#pragma mark - Track

#pragma mark - Option

#pragma mark - Delegate

- (void)callback:(void (^)(void))block
{
    if (!block)
    {
        return;
    }
    if (self.delegateQueue)
    {
        NSOperation * operation = [NSBlockOperation blockOperationWithBlock:^{
            block();
        }];
        [self.delegateQueue addOperation:operation];
    }
    else
    {
        block();
    }
}

- (void)callbackForTimingIfNeeded
{
    if (self.audioOutput.enable && !self.audioOutput.receivedFrame)
    {
        return;
    }
    if (self.videoOutput.enable && !self.videoOutput.receivedFrame)
    {
        return;
    }
    [self.stateLock lock];
    if (self.state == SGPlaybackStateSeeking ||
        self.state == SGPlaybackStateFailed)
    {
        [self.stateLock unlock];
        return;
    }
    [self.stateLock unlock];
    CMTime time = self.time;
    CMTime loadedTime = self.loadedTime;
    CMTime duration = self.duration;
    if (CMTimeCompare(time, self.lastTime) != 0 ||
        CMTimeCompare(loadedTime, self.lastLoadedTime) != 0 ||
        CMTimeCompare(duration, self.lastDuration) != 0)
    {
        self.lastTime = time;
        self.lastLoadedTime = loadedTime;
        self.lastDuration = duration;
        [self callback:^{
            [self.delegate playerDidChangeTimingInfo:self];
        }];
    }
}

#pragma mark - Internal

- (void)playAndPause
{
    [self.stateLock lock];
    if (self.state != SGPlaybackStatePlaying)
    {
        [self.stateLock unlock];
        [self.audioOutput pause];
        [self.videoOutput pause];
        return;
    }
    [self.stateLock unlock];
    [self.loadingStateLock lock];
    if (self.loadingState != SGLoadingStateLoading &&
        self.loadingState != SGLoadingStateFinished)
    {
        [self.loadingStateLock unlock];
        [self.audioOutput pause];
        [self.videoOutput pause];
        return;
    }
    [self.loadingStateLock unlock];
    if (self.session.empty)
    {
        [self.audioOutput pause];
        [self.videoOutput pause];
        return;
    }
    [self.audioOutput resume];
    [self.videoOutput resume];
}

- (void)destory
{
    [SGActivity removeTarget:self];
    [self.session close];
    self.session = nil;
    self.audioOutput = nil;
    self.videoOutput = nil;
    self.lastTime = CMTimeMake(-1900, 1);
    self.lastLoadedTime = CMTimeMake(-1900, 1);
    self.lastDuration = CMTimeMake(-1900, 1);
    _asset = nil;
    _error = nil;
}

#pragma mark - SGSessionDelegate

- (void)sessionDidChangeState:(SGSession *)session
{
    if (session.state == SGSessionStateOpened)
    {
        [session read];
        [self.loadingStateLock lock];
        SGBasicBlock loadingStateCallback = [self setLoadingState:SGLoadingStateLoading];
        [self.loadingStateLock unlock];
        loadingStateCallback();
    }
    else if (session.state == SGSessionStateFailed)
    {
        _error =  session.error;
        [self.stateLock lock];
        SGBasicBlock callback = [self setState:SGPlaybackStateFailed];
        [self.stateLock unlock];
        callback();
    }
}

- (void)sessionDidChangeCapacity:(SGSession *)session
{
    if (self.session.state == SGSessionStateFinished)
    {
        [self.loadingStateLock lock];
        SGBasicBlock loadingStateCallback = [self setLoadingState:SGLoadingStateFinished];
        [self.loadingStateLock unlock];
        loadingStateCallback();
    }
    if (self.session.state == SGSessionStateFinished && self.session.empty)
    {
        [self.stateLock lock];
        SGBasicBlock callback = [self setState:SGPlaybackStateFinished];
        [self.stateLock unlock];
        callback();
    }
    [self playAndPause];
    [self callbackForTimingIfNeeded];
}

@end
