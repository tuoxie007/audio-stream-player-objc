//
//  AudioStreamPlayer.m
//  AudioStreamPlayer
//
//  Created by Jason Hsu on 13/8/14.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import "HSUAudioStreamPlayer.h"
#import "HSUAudioDataProvider.h"
#import <AVFoundation/AVFoundation.h>
#include <pthread.h>

// As default: buffer memory = kMaxBufferSize * kMaxBufferQueueSize
#define kMaxBufferSize 2048
#define kMaxBufferQueueSize 300
#define kMinBufferQueueSize 3
#define kMaxPacketsNumber 512
#define HSUAudioStreamPlayerInterrupted (@"HSUAudioStreamPlayerInterrupted")

void HSUAudioFileStreamGetProperty(AudioFileStreamID stream, AudioFilePropertyID pid);
UInt32 HSUAudioFileStreamGetPropertyUInt32(AudioFileStreamID stream, AudioFilePropertyID pid);
UInt64 HSUAudioFileStreamGetPropertyUInt64(AudioFileStreamID stream, AudioFilePropertyID pid);
SInt64 HSUAudioFileStreamGetPropertySInt64(AudioFileStreamID stream, AudioFilePropertyID pid);
Float64 HSUAudioFileStreamGetPropertyFloat64(AudioFileStreamID stream, AudioFilePropertyID pid);
void *HSUAudioFileStreamGetPropertyUndefined(AudioFileStreamID stream, AudioFilePropertyID pid);

void HSUAudioQueueOutputCallback (void *                 inUserData,
                                  AudioQueueRef           inAQ,
                                  AudioQueueBufferRef     inBuffer);

void HSUAudioFileStreamPropertyListener (void *						inClientData,
                                         AudioFileStreamID			inAudioFileStream,
                                         AudioFileStreamPropertyID	inPropertyID,
                                         UInt32 *					ioFlags);

void HSUAudioPacketsCallback (void *						inClientData,
                              UInt32						inNumberBytes,
                              UInt32						inNumberPackets,
                              const void *					inInputData,
                              AudioStreamPacketDescription	*inPacketDescriptions);

void HSUAudioQueuePropertyChanged (void *                  inUserData,
                                   AudioQueueRef           inAQ,
                                   AudioQueuePropertyID    inID);

void HSUAudioSessionInterrupted (void * inClientData,
                                 UInt32 inInterruptionState);

@interface HSUAudioStreamPlayer ()

@property (readwrite) HSUAudioStreamPlayBackState state;

@end

@implementation HSUAudioStreamPlayer
{
    NSURL *_url;
    NSString *_cacheFilePath;
    
    HSUAudioDataProvider *_dataProvider;
    AudioQueueBufferRef _buffers[kMaxBufferQueueSize];
    NSUInteger _bufferPacketsCounts[kMaxBufferQueueSize];
    AudioStreamPacketDescription _bufferPacketDescs[kMaxBufferQueueSize][kMaxPacketsNumber];
    NSUInteger _enqueuedBufferCount;
    NSUInteger _dequeuedBufferCount;
    pthread_mutex_t _bufferMutex;
    pthread_cond_t _bufferCond;
    
    NSUInteger _bufferQueueSize;
    NSUInteger _bufferSize;
    NSUInteger _seekByteOffset;
    double _seekTime;
    
    BOOL _readingData;
    BOOL _readEnd;
    BOOL _userStop;
    BOOL _interrupted;
    BOOL _readError;
    
    NSUInteger _readPacketsNumber;
    NSUInteger _readBytesNumber;
    
    AudioFileStreamID _audioFileStream;
    AudioQueueRef _audioQueue;
    UInt32 _isRunning;
    AudioStreamBasicDescription _asbd;
    AudioQueueLevelMeterState *_meterStateOfChannels;
    
    HSUAudioStreamPlayBackState _state;
    dispatch_queue_t _dataEnqueueDP;
    
    OSStatus err;
}

- (void)dealloc
{
    pthread_mutex_destroy(&_bufferMutex);
    pthread_cond_destroy(&_bufferCond);
    if (_audioQueue) {
        AudioQueueDispose(_audioQueue, 0);
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithURL:(NSURL *)url
              cacheFilePath:(NSString *)cacheFilePath
{
    NSAssert(url || cacheFilePath, @"one of url and cache should be not nil");
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
        
        _audioSessionCategory = AVAudioSessionCategoryPlayback;
        _url = url;
        _cacheFilePath = [cacheFilePath copy];
        _dataEnqueueDP = dispatch_queue_create("me.tuoxie.audiostream", NULL);
        
        _bufferSize = kMaxBufferSize;
        
        pthread_mutex_init(&_bufferMutex, NULL);
        pthread_cond_init(&_bufferCond, NULL);
        
        self.state = HSU_AS_STOPPED;
    }
    return self;
}

// Call on main thread
- (void)play
{
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    _userStop = NO;
    if (self.state == HSU_AS_PAUSED) {
        err = AudioQueueStart(_audioQueue, NULL);
        if (err == noErr) {
            if (self.state == HSU_AS_PAUSED &&
                _enqueuedBufferCount > _dequeuedBufferCount) {
                self.state = HSU_AS_PLAYING;
            }
        } else {
            HLogErr(err);
        }
    } else {
        [self _start];
    }
}

- (void)stop
{
    _userStop = YES;
    if (_audioQueue && _isRunning) {
        CheckErr(AudioQueueStop(_audioQueue, true));
    } else {
        _seekByteOffset = 0;
        _seekTime = 0;
        self.state = HSU_AS_STOPPED;
    }
}

- (void)pause
{
    CheckErr(AudioQueuePause(_audioQueue));
    self.state = HSU_AS_PAUSED;
}

- (void)seekToTime:(double)time
{
    if (_streamDesc.bitrate) {
        _readPacketsNumber = 0;
        _readBytesNumber = 0;
        
        _seekTime = time;
        _seekByteOffset = _streamDesc.bitrate / 8 * _seekTime;
        if (_seekByteOffset == 0) {
            _seekByteOffset = -1;
        }
        
        pthread_mutex_lock(&_bufferMutex);
        pthread_cond_signal(&_bufferCond);
        pthread_mutex_unlock(&_bufferMutex);
        
        if ((_readEnd || _readError || _userStop) && _isRunning && _state != HSU_AS_PAUSED) {
            [self _start];
        }
    }
}

- (void)_start
{
#ifdef HSU_USE_IPHONE_6
    if (self.audioSessionCategory) {
        AVAudioSessionCategoryOptions options = 0;
        if (self.enableBlueTooth) {
            if ([self.audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
                [self.audioSessionCategory isEqualToString:AVAudioSessionCategoryRecord]) {
                options |= AVAudioSessionCategoryOptionAllowBluetooth;
            } else {
                HLog(@"Fail to enable bluebooth, self.audioCategory = %@", self.audioSessionCategory);
            }
        }
        [[AVAudioSession sharedInstance] setCategory:self.audioSessionCategory withOptions:options error:nil];
    } else if (self.enableBlueTooth) {
        HLog(@"Fail to enable bluebooth, self.audioCategory = %@", self.audioSessionCategory);
    }
#else
    if (self.audioSessionCategory) {
        [[AVAudioSession sharedInstance]
         setCategory:self.audioSessionCategory
         error:nil];
    }
    AudioSessionInitialize(NULL, NULL, HSUAudioSessionInterrupted, self);
    if (self.enableBlueTooth) {
        UInt32 enableBluetooth = true;
        AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput,
                                sizeof(enableBluetooth),
                                &enableBluetooth);
    }
#endif
    
    dispatch_async(_dataEnqueueDP, ^{
        [self _enqueueData];
    });
}

// DataProvider -> (Data) -> AudioStream
- (void)_enqueueData
{
    _readEnd = NO;
    while (!_userStop) {
        @autoreleasepool {
            if (_seekByteOffset) {
                //HLog(@"seek byte offset %u", _seekByteOffset);
                float packetNumPerSecond = _asbd.mSampleRate / _asbd.mFramesPerPacket;
                
                UInt32 ioFlags = 0;
                SInt64 packetAlignedByteOffset;
                SInt64 seekPacketOffset = floor(_seekTime * packetNumPerSecond);
                AudioFileStreamSeek(_audioFileStream,
                                    seekPacketOffset,
                                    &packetAlignedByteOffset,
                                    &ioFlags);
                
                if (_audioQueue && _isRunning) {
                    CheckErr(AudioQueueStop(_audioQueue, true));
                }
                _dataProvider = nil;
            }
            
            if (!_dataProvider) {
                if (_seekByteOffset == -1) {
                    _seekByteOffset = 0;
                }
                _dataProvider = [[HSUAudioDataProvider alloc]
                                 initWithURL:_url
                                 cacheFilePath:_cacheFilePath
                                 byteOffset:_seekByteOffset];
                _seekByteOffset = 0;
                AudioQueueDispose(_audioQueue, true);
                _audioQueue = nil;
                
                [[NSNotificationCenter defaultCenter]
                 addObserver:self
                 selector:@selector(_dataWait:)
                 name:HSUAudioStreamDataWait
                 object:_dataProvider];
            }
            
            _readingData = YES;
            _readError = NO;
            NSData *data = [_dataProvider readBufferWithMaxLength:_bufferSize
                                                            error:&_readError];
            if (_userStop) {
                _dataProvider = nil;
                break;
            }
            _readingData = NO;
            if (data.length) {
                if (!_audioFileStream) {
                    CheckErr(AudioFileStreamOpen((__bridge void *)self,
                                                 HSUAudioFileStreamPropertyListener,
                                                 HSUAudioPacketsCallback,
                                                 0,
                                                 &_audioFileStream));
                }
                AudioFileStreamParseBytes(_audioFileStream,
                                          data.length,
                                          data.bytes, 0);
            } else {
                if (!_readError) {
                    _readEnd = YES;
                } else {
                    HLog(@"Read Error");
                }
                _dataProvider = nil;
                
                // Flush tail
                if (!_audioQueue) {
                    [self _createQueue];
                }
                if (_audioQueue) {
                    AudioQueueStart(_audioQueue, 0);
                    self.state = HSU_AS_PLAYING;
                    AudioQueueFlush(_audioQueue);
                    AudioQueueStop(_audioQueue, false);
                }
                break;
            }
        }
    }
}

// AudioStream -> (Packets) -> AudioQueue
- (void)handleAudioPackets:(const void *)packets
               numberBytes:(UInt32)numberBytes
             numberPackets:(UInt32)numberPackets
               packetDescs:(AudioStreamPacketDescription *)packetDescs
{
    if (!_audioQueue) {
        [self _createQueue];
    }
    
    NSUInteger bufferIndex = _enqueuedBufferCount % _bufferQueueSize;
    memcpy((char *)_buffers[bufferIndex]->mAudioData, (const char *)packets, numberBytes);
    _buffers[bufferIndex]->mAudioDataByteSize = numberBytes;
    _bufferPacketsCounts[bufferIndex] = numberPackets;
    for (int i=0; i<numberPackets; i++) {
        _bufferPacketDescs[bufferIndex][i] = packetDescs[i];
    }
    
    _readPacketsNumber += numberPackets;
    _readBytesNumber += numberBytes;
    if (_readPacketsNumber > 50) {
        _streamDesc.bitrate = (double)_readBytesNumber / _readPacketsNumber / _asbd.mFramesPerPacket * _asbd.mSampleRate * 8;
        if (_dataProvider.contentLength) {
            _streamDesc.duration = _dataProvider.contentLength / (_streamDesc.bitrate / 8);
        }
    }
    
    pthread_mutex_lock(&_bufferMutex);
    while (_enqueuedBufferCount - _dequeuedBufferCount >= _bufferQueueSize - kMinBufferQueueSize) {
        if (self.state != HSU_AS_PAUSED) {
            AudioQueueStart(_audioQueue, 0);
            self.state = HSU_AS_PLAYING;
        }
        pthread_cond_wait(&_bufferCond, &_bufferMutex);
    }
    AudioQueueEnqueueBuffer(_audioQueue, _buffers[bufferIndex],
                            _bufferPacketsCounts[bufferIndex],
                            _bufferPacketDescs[bufferIndex]);
    _enqueuedBufferCount ++;
    pthread_mutex_unlock(&_bufferMutex);
}

// AudioQueue consumed a buffer
- (void)handleAudioQueueOutputBuffer:(AudioQueueBufferRef)buffer
{
    pthread_mutex_lock(&_bufferMutex);
    _dequeuedBufferCount ++;
    if (_readingData && _dequeuedBufferCount >= _enqueuedBufferCount) {
        if (self.state == HSU_AS_PLAYING) {
            self.state = HSU_AS_WAITTING;
            AudioQueuePause(_audioQueue);
        }
    }
    pthread_cond_signal(&_bufferCond);
    pthread_mutex_unlock(&_bufferMutex);
}

// isRunning changed
- (OSStatus)handleAudioQueuePropertyChanged:(AudioQueuePropertyID)pid
{
    if (pid == kAudioQueueProperty_IsRunning)
    {
        UInt32 size = sizeof(UInt32);
        AudioQueueGetProperty(_audioQueue, pid, &_isRunning, &size);
        if (_isRunning == 0) {
            // reset variables
            _readPacketsNumber = 0;
            _readBytesNumber = 0;
            _enqueuedBufferCount = 0;
            _dequeuedBufferCount = 0;
            
            if (_readEnd) {
                _seekByteOffset = 0;
                _seekTime = 0;
                self.state = HSU_AS_FINISHED;
            } else if (_userStop) {
                _seekByteOffset = 0;
                _seekTime = 0;
                self.state = HSU_AS_STOPPED;
            } else if (_readError) {
                self.state = HSU_AS_ERROR;
            }
        } else {
            self.state = HSU_AS_PLAYING;
        }
    }
    return noErr;
}

- (double)currentTime
{
    if (_audioQueue) {
        AudioTimeStamp queueTime;
        err = AudioQueueGetCurrentTime(_audioQueue, NULL, &queueTime, NULL);
        if (err == noErr) {
            return _seekTime + queueTime.mSampleTime / _asbd.mSampleRate;
        }
    }
    return _seekTime;
}

- (double)progress
{
    if (self.duration) {
        return MIN([self currentTime] / self.duration, 1);
    }
    return 0;
}

- (double)duration
{
    return _streamDesc.duration;
}

- (HSUAudioStreamPlayBackState)state
{
    return _state;
}

- (void)setState:(HSUAudioStreamPlayBackState)state
{
    if (_state != state) {
        //HLog(@"state %@", stateText(state));
        if (state == HSU_AS_STOPPED) {
            
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            _state = state;
            [[NSNotificationCenter defaultCenter]
             postNotificationName:HSUAudioStreamPlayerStateChanged
             object:self];
        });
    }
}

- (void)_dataWait:(NSNotification *)notification
{
    self.state = HSU_AS_WAITTING;
}

- (void)_createQueue
{
    if (!_asbd.mSampleRate) {
        return;
    }
	_streamDesc.sampleRate = _asbd.mSampleRate;
	
    CheckErr(AudioQueueNewOutput(&_asbd,
                                 HSUAudioQueueOutputCallback,
                                 (__bridge void *)self,
                                 NULL,
                                 NULL,
                                 0,
                                 &_audioQueue));
    CheckErr(AudioQueueAddPropertyListener(_audioQueue,
                                           kAudioQueueProperty_IsRunning,
                                           HSUAudioQueuePropertyChanged,
                                           (__bridge void *)self));
	
	UInt32 sizeOfUInt32 = sizeof(UInt32);
    err = AudioFileStreamGetProperty(_audioFileStream,
                                     kAudioFileStreamProperty_PacketSizeUpperBound,
                                     &sizeOfUInt32,
                                     &_bufferSize);
	if (err || _bufferSize == 0) {
		err = AudioFileStreamGetProperty(_audioFileStream,
                                         kAudioFileStreamProperty_MaximumPacketSize,
                                         &sizeOfUInt32,
                                         &_bufferSize);
		if (err || _bufferSize == 0) {
            _bufferSize = kMaxBufferSize;
		}
	}
    
    _bufferQueueSize = kMaxBufferQueueSize;
    if (_bufferByteSize &&
        _bufferByteSize >= _bufferSize * 3 &&
        _bufferByteSize <= _bufferSize * kMaxBufferQueueSize) {
        _bufferQueueSize = _bufferByteSize / _bufferSize;
    } else {
        if (_bufferByteSize) {
            HLog(@"bufferByteSize invalid, use default %u", _bufferSize * _bufferQueueSize);
        }
        _bufferByteSize = _bufferQueueSize * _bufferSize;
    }
    
    for (int i = 0; i < _bufferQueueSize; i++) {
        AudioQueueAllocateBuffer(_audioQueue,
                                 _bufferSize,
                                 &_buffers[i]);
    }
    
    if (_enableLevelMetering) {
        UInt32 enableLevelMetering = 1;
        AudioQueueSetProperty(_audioQueue,
                              kAudioQueueProperty_EnableLevelMetering,
                              &enableLevelMetering,
                              sizeof(UInt32));
    }
    
    if (self.useSoftwareCodec) {
        UInt32 val = kAudioQueueHardwareCodecPolicy_PreferSoftware;
        AudioQueueSetProperty(_audioQueue,
                              kAudioQueueProperty_HardwareCodecPolicy,
                              &val,
                              sizeof(UInt32));
    }
    
    
	UInt32 cookieSize;
	Boolean writable;
	OSStatus ignorableError;
	ignorableError = AudioFileStreamGetPropertyInfo(_audioFileStream,
                                                    kAudioFileStreamProperty_MagicCookieData,
                                                    &cookieSize,
                                                    &writable);
	if (ignorableError) {
		return;
	}
    
	// get the cookie data
	void* cookieData = calloc(1, cookieSize);
	ignorableError = AudioFileStreamGetProperty(_audioFileStream,
                                                kAudioFileStreamProperty_MagicCookieData,
                                                &cookieSize,
                                                cookieData);
	if (ignorableError) {
		return;
	}
    
	// set the cookie on the queue.
	ignorableError = AudioQueueSetProperty(_audioQueue,
                                           kAudioQueueProperty_MagicCookie,
                                           cookieData,
                                           cookieSize);
	free(cookieData);
	if (ignorableError) {
		return;
	}
}

// read stream description, formats
- (void)handleAudioFileStreamPropertyChanged:(AudioFileStreamPropertyID)propertyID
                                     ioFlags:(UInt32 *)ioFlags
{
    if (propertyID == kAudioFileStreamProperty_DataFormat)
    {
        if (_asbd.mSampleRate == 0) {
            UInt32 asbdSize = sizeof(_asbd);
            
            CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                                kAudioFileStreamProperty_DataFormat,
                                                &asbdSize,
                                                &_asbd));
            _meterStateOfChannels =
            (AudioQueueLevelMeterState *)malloc(sizeof(AudioQueueLevelMeterState) *_asbd.mChannelsPerFrame);
            memset(_meterStateOfChannels, 0, sizeof(AudioQueueLevelMeterState) * _asbd.mChannelsPerFrame);
            _streamDesc.channels = _asbd.mChannelsPerFrame;
        }
    }
    else if (propertyID == kAudioFileStreamProperty_FormatList)
    {
        Boolean outWriteable;
        UInt32 formatListSize;
        CheckErr(AudioFileStreamGetPropertyInfo(_audioFileStream,
                                                kAudioFileStreamProperty_FormatList,
                                                &formatListSize,
                                                &outWriteable));
        AudioFormatListItem *formatList = malloc(formatListSize);
        CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                            kAudioFileStreamProperty_FormatList,
                                            &formatListSize,
                                            formatList));
        for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
        {
            AudioStreamBasicDescription pasbd = formatList[i].mASBD;
            
            if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE ||
                pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
            {
#if !TARGET_IPHONE_SIMULATOR
                _asbd = pasbd;
#endif
                break;
            }
        }
        free(formatList);
    }
}

- (void)handleInterruption:(NSNotification *)notification {
    AVAudioSessionInterruptionType interruptionType =
    [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        if (self.state == HSU_AS_PLAYING) {
            _interrupted = YES;
            [self pause];
        }
	} else if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        if (_interrupted) {
            _interrupted = NO;
            [self play];
        }
	}
}

- (float)averagePowerForChannel:(int)channel
{
    if (_asbd.mChannelsPerFrame == 0) {
        return 0;
    }
    UInt32 propertySize = sizeof(AudioQueueLevelMeterState) * _asbd.mChannelsPerFrame;
    AudioQueueGetProperty(_audioQueue, kAudioQueueProperty_CurrentLevelMeterDB, _meterStateOfChannels, &propertySize);
    return _meterStateOfChannels[channel].mAveragePower;
}

- (float)currentVolume
{
    float power = 0;
    for (int i=0; i<_asbd.mChannelsPerFrame; i++) {
        float channelPower = powf(10, [self averagePowerForChannel:0] / 2 / 20);
        if (channelPower < 1) {
            power += channelPower;
        }
    }
    return power / _asbd.mChannelsPerFrame;
}

@end

void HSUAudioQueueOutputCallback(void *                  inUserData,
                                 AudioQueueRef           inAQ,
                                 AudioQueueBufferRef     inBuffer)
{
    HSUAudioStreamPlayer *player = (__bridge HSUAudioStreamPlayer *)inUserData;
    [player handleAudioQueueOutputBuffer:inBuffer];
}

void HSUAudioFileStreamPropertyListener (void *						inClientData,
                                         AudioFileStreamID			inAudioFileStream,
                                         AudioFileStreamPropertyID	inPropertyID,
                                         UInt32 *					ioFlags)
{
    HSUAudioStreamPlayer *player = (__bridge HSUAudioStreamPlayer *)inClientData;
    [player handleAudioFileStreamPropertyChanged:inPropertyID
                                         ioFlags:ioFlags];
}

void HSUAudioPacketsCallback (void *						inClientData,
                              UInt32						inNumberBytes,
                              UInt32						inNumberPackets,
                              const void *					inInputData,
                              AudioStreamPacketDescription	*inPacketDescriptions)
{
    HSUAudioStreamPlayer *player = (__bridge HSUAudioStreamPlayer *)inClientData;
    [player handleAudioPackets:inInputData
                   numberBytes:inNumberBytes
                 numberPackets:inNumberPackets
                   packetDescs:inPacketDescriptions];
}

void HSUAudioQueuePropertyChanged (void *                  inUserData,
                                   AudioQueueRef           inAQ,
                                   AudioQueuePropertyID    inID)
{
    HSUAudioStreamPlayer *player = (__bridge HSUAudioStreamPlayer *)inUserData;
    [player handleAudioQueuePropertyChanged:inID];
}

void HSUAudioSessionInterrupted (void * inClientData,
                                 UInt32 inInterruptionState)
{
    NSDictionary *userInfo = nil;
    if (inInterruptionState == kAudioSessionBeginInterruption) {
        userInfo = @{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)};
    } else if (inInterruptionState == kAudioSessionEndInterruption) {
        userInfo = @{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeEnded)};
    }
    [[NSNotificationCenter defaultCenter]
     postNotificationName:AVAudioSessionInterruptionNotification
     object:userInfo];
}

NSString *stateText(HSUAudioStreamPlayBackState state)
{
    switch (state) {
        case HSU_AS_STOPPED:
            return @"STOPPED";
            
        case HSU_AS_WAITTING:
            return @"WAITTING";
            
        case HSU_AS_PLAYING:
            return @"PLAYING";
            
        case HSU_AS_PAUSED:
            return @"PAUSED";
            
        case HSU_AS_FINISHED:
            return @"FINISHED";
            
        case HSU_AS_ERROR:
            return @"ERROR";
            
        default:
            break;
    }
}
