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

void HSUAudioFileStreamGetProperty(AudioFileStreamID stream, AudioFilePropertyID pid);
UInt32 HSUAudioFileStreamGetPropertyUInt32(AudioFileStreamID stream, AudioFilePropertyID pid);
UInt64 HSUAudioFileStreamGetPropertyUInt64(AudioFileStreamID stream, AudioFilePropertyID pid);
SInt64 HSUAudioFileStreamGetPropertySInt64(AudioFileStreamID stream, AudioFilePropertyID pid);
Float64 HSUAudioFileStreamGetPropertyFloat64(AudioFileStreamID stream, AudioFilePropertyID pid);
void *HSUAudioFileStreamGetPropertyUndefined(AudioFileStreamID stream, AudioFilePropertyID pid);

void HSUAudioQueueOutputCallback (void *                  inUserData,
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

AudioFileTypeID hintForFileExtension(NSString *fileExtension);

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
    AudioStreamPacketDescription *_bufferPacketDescs[kMaxBufferQueueSize];
    NSUInteger _enqueuedBufferCount;
    NSUInteger _dequeuedBufferCount;
    pthread_mutex_t _bufferMutex;
    pthread_cond_t _bufferCond;
    
    NSUInteger _bufferQueueSize;
    NSUInteger _bufferSize;
    NSUInteger _seekByteOffset;
    double _seekTime;
    NSUInteger _currentOffset;
    NSUInteger _dataStartOffset;
    
    BOOL _readingData;
    BOOL _readEnd;
    BOOL _userStop;
    BOOL _interrupted;
    BOOL _readError;
    
    NSUInteger _consumedAudioPacketsNumber;
    NSUInteger _consumedAudioBytesNumber;
    
    AudioFileStreamID _audioFileStream;
    AudioQueueRef _audioQueue;
    UInt32 _isRunning;
    AudioStreamBasicDescription _asbd;
    AudioQueueLevelMeterState *_meterStateOfChannels;
    double _bitrate;
    
    HSUAudioStreamPlayBackState _state;
    dispatch_queue_t _dataEnqueueDP;
    
    OSStatus err;
}

- (void)dealloc
{
    @synchronized(self) {
        _dataProvider = nil;
        _url = nil;
        _cacheFilePath = nil;
        pthread_mutex_destroy(&_bufferMutex);
        pthread_cond_destroy(&_bufferCond);
        if (_audioQueue) {
            AudioQueueDispose(_audioQueue, 0);
            _audioQueue = nil;
        }
        //dispatch_release(_dataEnqueueDP);
        free(_meterStateOfChannels);
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (instancetype)initWithURL:(NSURL *)url
              cacheFilePath:(NSString *)cacheFilePath
{
    NSAssert(url || cacheFilePath, @"one of url and cache should be not nil");
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(handleInterruption:)
         name:IPHONE_6_OR_LATER ? AVAudioSessionInterruptionNotification : @"AVAudioSessionInterruptionNotification"
         object:nil];
        
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
    
    if (self.state == HSU_AS_ERROR && !_seekByteOffset) {
        _seekByteOffset = _currentOffset;
    }
    
    BOOL restart;
    if (self.state == HSU_AS_PAUSED && _audioQueue && _isRunning) { // paused
        if (_seekByteOffset) { // seeking
            if (_readEnd || _readError) { // read end
                restart = YES;
            } else {
                restart = NO;
            }
        } else {
            restart = NO;
        }
    } else {
        restart = YES;
    }
    
    if (restart) {
        [self _start];
    } else {
        BOOL seek = _seekByteOffset > 0;
        OSStatus error = AudioQueueStart(_audioQueue, NULL);
        if (error == noErr) {
            BOOL hasBuffer = _enqueuedBufferCount > _dequeuedBufferCount;
            if (seek || !hasBuffer) {
                self.state = HSU_AS_WAITTING;
            } else {
                self.state = HSU_AS_PLAYING;
            }
        } else {
            HLogErr(error);
        }
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
        [_dataProvider close];
    }
}

- (void)pause
{
    CheckErr(AudioQueuePause(_audioQueue));
    self.state = HSU_AS_PAUSED;
}

- (void)seekToTime:(double)time
{
    if (self.bitrate) {
        _consumedAudioPacketsNumber = 0;
        _consumedAudioBytesNumber = 0;
        
        _seekTime = time;
        _seekByteOffset = self.bitrate / 8 * _seekTime + _dataStartOffset;
        if (_seekByteOffset == 0) {
            _seekByteOffset = -1;
        }
        
        pthread_mutex_lock(&_bufferMutex);
        pthread_cond_signal(&_bufferCond);
        pthread_mutex_unlock(&_bufferMutex);
        
        if ((_readEnd || _readError || _userStop) && _isRunning && _state != HSU_AS_PAUSED) {
            [self _start];
        }
    } else {
        _seekTime = time;
    }
}

- (void)_start
{
    __weak typeof(self)weakSelf = self;
    dispatch_async(_dataEnqueueDP, ^{
        [weakSelf _enqueueData];
    });
}

// DataProvider -> (Data) -> AudioStream
- (void)_enqueueData
{
    _readEnd = NO;
    while (!_userStop) {
        @autoreleasepool {
            if (_seekByteOffset) {
                float packetRate = _asbd.mSampleRate / _asbd.mFramesPerPacket;
                
                UInt32 ioFlags = 0;
                SInt64 packetAlignedByteOffset;
                SInt64 seekPacketOffset = floor(_seekTime * packetRate);
                OSStatus error = AudioFileStreamSeek(_audioFileStream,
                                                     seekPacketOffset,
                                                     &packetAlignedByteOffset,
                                                     &ioFlags);
                if (!error && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated)) {
                    _seekTime = packetAlignedByteOffset * 8 / self.bitrate;
                    _seekByteOffset = packetAlignedByteOffset + _dataStartOffset;
                }
                if (error) {
                    HLogErr(error);
                }
                
                if (_audioQueue && _isRunning) {
                    CheckErr(AudioQueueStop(_audioQueue, true));
                }
                _dataProvider = nil;
            }
            
            if (!_dataProvider) {
                if (_seekTime && !_seekByteOffset) {
                    self.state = HSU_AS_WAITTING;
                }
                if (_seekByteOffset == -1) {
                    _seekByteOffset = 0;
                }
                _dataProvider = [[HSUAudioDataProvider alloc]
                                 initWithURL:_url
                                 cacheFilePath:_cacheFilePath
                                 byteOffset:_seekByteOffset];
                _dataProvider.cacheEncryptor = self.cacheEncryptor;
                _currentOffset = _seekByteOffset;
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
                if (!_streamDesc.contentLength) {
                    _streamDesc.contentLength = _dataProvider.contentLength;
                    if (self.presetDuration) {
                        _bitrate = _streamDesc.contentLength / self.presetDuration * 8;
                        if (self.bufferAudioSeconds) {
                            NSInteger bufferByteSize = self.bufferAudioSeconds * self.bitrate / 8;
                            if (bufferByteSize > self.bufferByteSize) {
                                self.bufferByteSize = bufferByteSize;
                            }
                        }
                    }
                }
                _currentOffset += data.length;
                if (!_audioFileStream) {
                    if (!self.fileType) {
                        NSString *extension = _url.pathExtension;
                        self.fileType = hintForFileExtension(extension);
                    }
                    
                    CheckErr(AudioFileStreamOpen((__bridge void *)self,
                                                 HSUAudioFileStreamPropertyListener,
                                                 HSUAudioPacketsCallback,
                                                 self.fileType,
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
                
                NSUInteger startOffset = _dataProvider.startOffset;
                _dataProvider = nil;
                
                if (_currentOffset > startOffset) {
                    // Flush tail
                    if (!_audioQueue) {
                        [self _createQueue];
                    }
                    if (_audioQueue) {
                        AudioQueueStart(_audioQueue, 0);
                        self.state = HSU_AS_PLAYING;
                        AudioQueueFlush(_audioQueue);
                        AudioQueueStop(_audioQueue, false);
                    } else {
                        self.state = HSU_AS_ERROR;
                    }
                } else if (startOffset >= _dataProvider.contentLength) {
                    self.state = HSU_AS_FINISHED;
                } else {
                    self.state = HSU_AS_ERROR;
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
    
    if (self.state == HSU_AS_ERROR) {
        return;
    }
    
    NSUInteger bufferIndex = _enqueuedBufferCount % _bufferQueueSize;
    memcpy((char *)_buffers[bufferIndex]->mAudioData, (const char *)packets, numberBytes);
    _buffers[bufferIndex]->mAudioDataByteSize = numberBytes;
    _bufferPacketsCounts[bufferIndex] = numberPackets;
    _bufferPacketDescs[bufferIndex] = packetDescs;
    
    if (!_streamDesc.bitrate || !_streamDesc.duration || _correctBitrate) {
        // compute averiage bitrate if not specified in stream info or need correct bitrate
        _consumedAudioPacketsNumber += numberPackets;
        _consumedAudioBytesNumber += numberBytes;
        if (_consumedAudioPacketsNumber >= 50 && _consumedAudioPacketsNumber % 10 == 0) {
            if (!_streamDesc.bitrate || _correctBitrate) {
                BOOL first = !self.bitrate;
                _streamDesc.bitrate = (double)_consumedAudioBytesNumber / _consumedAudioPacketsNumber / _asbd.mFramesPerPacket * _asbd.mSampleRate * 8;
                if (first) {
                    if (_seekTime) {
                        _seekByteOffset = _seekTime * self.bitrate / 8 + _dataStartOffset;
                    }
                }
            }
            if (!_streamDesc.duration || _correctBitrate) {
                if (_streamDesc.dataByteCount) {
                    _streamDesc.duration = _streamDesc.dataByteCount / (self.bitrate / 8);
                } else if (_streamDesc.contentLength) {
                    _streamDesc.duration = _streamDesc.contentLength / (self.bitrate / 8);
                }
                __weak typeof(self)weakSelf = self;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                     postNotificationName:HSUAudioStreamPlayerDurationUpdatedNotification
                     object:weakSelf];
                });
            }
        }
    }
    
    pthread_mutex_lock(&_bufferMutex);
    while (_enqueuedBufferCount - _dequeuedBufferCount >= _bufferQueueSize - kMinBufferQueueSize) {
        if (self.state != HSU_AS_PAUSED) {
            OSStatus error = AudioQueueStart(_audioQueue, 0);
            if (error) {
                HLogErr(error);
            }
            self.state = HSU_AS_PLAYING;
        }
        pthread_cond_wait(&_bufferCond, &_bufferMutex);
    }
    OSStatus error = AudioQueueEnqueueBuffer(_audioQueue,
                                             _buffers[bufferIndex],
                                             _bufferPacketsCounts[bufferIndex],
                                             _bufferPacketDescs[bufferIndex]);
    if (error) {
        HLogErr(error);
    }
    _enqueuedBufferCount ++;
    pthread_mutex_unlock(&_bufferMutex);
}

// AudioQueue consumed a buffer
- (void)handleAudioQueueOutputBuffer:(AudioQueueBufferRef)buffer
{
    pthread_mutex_lock(&_bufferMutex);
    _dequeuedBufferCount ++;
    if (_dequeuedBufferCount >= _enqueuedBufferCount) {
        if (_readingData) {
            if (self.state == HSU_AS_PLAYING) {
                self.state = HSU_AS_WAITTING;
                AudioQueuePause(_audioQueue);
            }
        }
    }
    pthread_cond_signal(&_bufferCond);
    pthread_mutex_unlock(&_bufferMutex);
}

// isRunning changed
- (OSStatus)handleAudioQueuePropertyChanged:(AudioQueuePropertyID)pid
{
    @synchronized(self) {
        if (pid == kAudioQueueProperty_IsRunning)
        {
            UInt32 size = sizeof(UInt32);
            AudioQueueGetProperty(_audioQueue, pid, &_isRunning, &size);
            if (_isRunning == 0) {
                // reset variables
                _consumedAudioPacketsNumber = 0;
                _consumedAudioBytesNumber = 0;
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
                    _seekByteOffset = _currentOffset;
                    _seekTime = _seekByteOffset / self.bitrate * 8;
                    __weak typeof(self)weakSelf = self;
                    dispatch_async(_dataEnqueueDP, ^{
                        [weakSelf _enqueueData];
                    });
                }
            } else {
                self.state = HSU_AS_PLAYING;
            }
        }
        return noErr;
    }
}

- (NSUInteger)dataOffset
{
    return _currentOffset;
}

- (double)currentTime
{
    if (_audioQueue && !_seekByteOffset) {
        AudioTimeStamp queueTime;
        OSStatus error = AudioQueueGetCurrentTime(_audioQueue, NULL, &queueTime, NULL);
        if (error == noErr) {
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
    return self.presetDuration ?: _streamDesc.duration;
}

- (double)bitrate
{
    return _bitrate ?: _streamDesc.bitrate;
}

- (HSUAudioStreamPlayBackState)state
{
    return _state;
}

- (void)setState:(HSUAudioStreamPlayBackState)state
{
    if (_state != state) {
        _state = state;
        //HLog(@"state %@", stateText(state));
        __weak typeof(self)weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf) {
                _state = state;
                [[NSNotificationCenter defaultCenter]
                 postNotificationName:HSUAudioStreamPlayerStateChangedNotification
                 object:weakSelf];
            }
        });
    }
}

- (void)setEnableHeadset:(BOOL)enableHeadset
{
    _enableHeadset = enableHeadset;
    if (_audioQueue) {
        [self _setupCategory];
    }
}

- (void)_setupCategory
{
    if (IPHONE_6_OR_LATER) {
        if (self.audioSessionCategory) {
            AVAudioSessionCategoryOptions options = 0;
            if (self.enableBlueTooth) {
                if ([self.audioSessionCategory isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
                    [self.audioSessionCategory isEqualToString:AVAudioSessionCategoryRecord]) {
                    options |= AVAudioSessionCategoryOptionAllowBluetooth;
                } else {
                    HLog(@"Fail to enable bluebooth, self.audioCategory = %@", self.audioSessionCategory);
                }
                if (!self.enableHeadset) {
                    options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
                }
            }
            [[AVAudioSession sharedInstance]
             setCategory:self.audioSessionCategory
             withOptions:options
             error:nil];
        } else if (self.enableBlueTooth) {
            HLog(@"Fail to enable bluebooth, self.audioCategory = %@", self.audioSessionCategory);
        }
    } else {
#ifndef __IPHONE_7_0
        if (self.audioSessionCategory) {
            [[AVAudioSession sharedInstance]
             setCategory:self.audioSessionCategory
             error:nil];
        }
        if (!_audioQueue) {
            AudioSessionInitialize(NULL, NULL, HSUAudioSessionInterrupted, (__bridge void *)(self));
        }
        if (self.enableBlueTooth) {
            UInt32 enableBluetooth = true;
            AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryEnableBluetoothInput,
                                    sizeof(enableBluetooth),
                                    &enableBluetooth);
        }
        if (!self.enableHeadset) {
            UInt32 defaultToSpeaker = true;
            AudioSessionSetProperty(kAudioSessionProperty_OverrideCategoryDefaultToSpeaker,
                                    sizeof(defaultToSpeaker),
                                    &defaultToSpeaker);
        }
#endif
    }
#ifndef __IPHONE_7_0
    if (self.enableHeadset) {
        UInt32 audioRouteOverride = kAudioSessionOverrideAudioRoute_None;
        AudioSessionSetProperty(kAudioSessionProperty_OverrideAudioRoute, sizeof(audioRouteOverride), &audioRouteOverride);
    }
#endif
}

- (void)_dataWait:(NSNotification *)notification
{
    self.state = HSU_AS_WAITTING;
}

- (void)_computeBufferQueueSize
{
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
}

- (void)_createQueue
{
    if (!_asbd.mSampleRate) {
        return;
    }
    [self _setupCategory];
	_streamDesc.sampleRate = _asbd.mSampleRate;
	
    CheckErr(AudioQueueNewOutput(&_asbd,
                                 HSUAudioQueueOutputCallback,
                                 (__bridge void *)self,
                                 CFRunLoopGetMain(),
                                 kCFRunLoopCommonModes,
                                 0,
                                 &_audioQueue));
    CheckErr(AudioQueueAddPropertyListener(_audioQueue,
                                           kAudioQueueProperty_IsRunning,
                                           HSUAudioQueuePropertyChanged,
                                           (__bridge void *)self));
	
	UInt32 sizeOfUInt32 = sizeof(UInt32);
    AudioFileStreamGetProperty(_audioFileStream,
                                     kAudioFileStreamProperty_PacketSizeUpperBound,
                                     &sizeOfUInt32,
                                     &_bufferSize);
//	if (error) {
//		error = AudioFileStreamGetProperty(_audioFileStream,
//                                         kAudioFileStreamProperty_MaximumPacketSize,
//                                         &sizeOfUInt32,
//                                         &_bufferSize);
//	}
    
    [self _computeBufferQueueSize];
    
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
//    HLog(@"propertyID %d, %c%c%c%c",
//         (int)propertyID,
//         ((char *)&propertyID)[3],
//         ((char *)&propertyID)[2],
//         ((char *)&propertyID)[1],
//         ((char *)&propertyID)[0]);
    
    if (propertyID == kAudioFileStreamProperty_BitRate)
    {
        UInt32 bitrate = 0;
        UInt32 psize = sizeof(UInt32);
        CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                            propertyID,
                                            &psize,
                                            &bitrate));
        if (bitrate > 1000) {
            _streamDesc.bitrate = bitrate;
        } else {
            _streamDesc.bitrate = bitrate * 1000;
        }
        if (self.bufferAudioSeconds && _bitrate == 0) {
            NSInteger bufferByteSize = self.bufferAudioSeconds * self.bitrate / 8;
            if (bufferByteSize > self.bufferByteSize) {
                self.bufferByteSize = bufferByteSize;
            }
        }
    }
    else if (propertyID == kAudioFileStreamProperty_AudioDataByteCount)
    {
        UInt32 psize = sizeof(_streamDesc.dataByteCount);
        CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                            propertyID,
                                            &psize,
                                            &_streamDesc.dataByteCount));
        if (self.bitrate) {
            _streamDesc.duration = _streamDesc.dataByteCount / self.bitrate * 8;
        }
    }
    else if (propertyID == kAudioFileStreamProperty_DataFormat)
    {
        if (_asbd.mSampleRate == 0) {
            UInt32 asbdSize = sizeof(_asbd);
            
            CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                                propertyID,
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
                                                propertyID,
                                                &formatListSize,
                                                &outWriteable));
        AudioFormatListItem *formatList = malloc(formatListSize);
        CheckErr(AudioFileStreamGetProperty(_audioFileStream,
                                            propertyID,
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
    else if (propertyID == kAudioFileStreamProperty_DataOffset)
    {
        UInt32 psize = sizeof(SInt64);
        AudioFileStreamGetProperty(_audioFileStream, propertyID, &psize, &_dataStartOffset);
    }
    if (_asbd.mSampleRate && self.bitrate && _seekTime) { // got format
        _seekByteOffset = _seekTime * self.bitrate / 8 + _dataStartOffset;
    }
}

- (void)handleInterruption:(NSNotification *)notification {
    AVAudioSessionInterruptionType interruptionType =
    [notification.userInfo[IPHONE_6_OR_LATER ? AVAudioSessionInterruptionTypeKey : @"AVAudioSessionInterruptionTypeKey"] unsignedIntegerValue];
	if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        if (self.state == HSU_AS_PLAYING) {
            _interrupted = YES;
            [self pause];
        }
	} else if (interruptionType == AVAudioSessionInterruptionTypeEnded) {
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
        userInfo = @{@"AVAudioSessionInterruptionTypeKey": @(AVAudioSessionInterruptionTypeBegan)};
    } else if (inInterruptionState == kAudioSessionEndInterruption) {
        userInfo = @{@"AVAudioSessionInterruptionTypeKey": @(AVAudioSessionInterruptionTypeEnded)};
    } else {
        return;
    }
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:@"AVAudioSessionInterruptionNotification"
     object:nil
     userInfo:userInfo];
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

AudioFileTypeID hintForFileExtension(NSString *fileExtension)
{
	AudioFileTypeID fileTypeHint = 0;
	if ([fileExtension isEqual:@"mp3"])
	{
		fileTypeHint = kAudioFileMP3Type;
	}
	else if ([fileExtension isEqual:@"wav"])
	{
		fileTypeHint = kAudioFileWAVEType;
	}
	else if ([fileExtension isEqual:@"aifc"])
	{
		fileTypeHint = kAudioFileAIFCType;
	}
	else if ([fileExtension isEqual:@"aiff"])
	{
		fileTypeHint = kAudioFileAIFFType;
	}
	else if ([fileExtension isEqual:@"m4a"])
	{
		fileTypeHint = kAudioFileM4AType;
	}
	else if ([fileExtension isEqual:@"mp4"])
	{
		fileTypeHint = kAudioFileMPEG4Type;
	}
	else if ([fileExtension isEqual:@"caf"])
	{
		fileTypeHint = kAudioFileCAFType;
	}
	else if ([fileExtension isEqual:@"aac"])
	{
		fileTypeHint = kAudioFileAAC_ADTSType;
	}
	return fileTypeHint;
}