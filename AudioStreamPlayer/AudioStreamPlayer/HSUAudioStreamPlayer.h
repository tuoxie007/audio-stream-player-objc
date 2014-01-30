//
//  AudioStreamPlayer.h
//  AudioStreamPlayer
//
//  Created by Jason Hsu on 13/8/14.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

#import "HSUAudioCacheControl.h"
#import "HSUAudioNetworkControl.h"
#import "HSUAudioDataProvider.h"

#define HSUAudioStreamPlayerStateChangedNotification (@"HSUAudioStreamPlayerStateChangedNotification")
#define HSUAudioStreamPlayerDurationUpdatedNotification (@"HSUAudioStreamPlayerDurationUpdatedNotification")
#define HSUDefaultAudioCacheFileEncryptorPassword 200


#ifdef DEBUG
#define HLOG_LINENUMBER_METHOD(s,...) NSLog((@"[Line %d] %s " s), __LINE__, __PRETTY_FUNCTION__, ##__VA_ARGS__);
#define HLog(s,...) HLOG_LINENUMBER_METHOD(s, ##__VA_ARGS__)
#else
#define HLog(s,...)
#endif

#define HLogErr(err) \
    if (err != noErr) { \
        HLog(@"Error %d, %c%c%c%c", \
        (int)err, \
        ((char *)&err)[3], \
        ((char *)&err)[2], \
        ((char *)&err)[1], \
        ((char *)&err)[0]); \
    }

#ifdef DEBUG
#define CheckErr(arg) \
    err = arg; \
    if (err != noErr) { \
        HLogErr(err); \
        self.state = HSU_AS_ERROR; \
        return; \
    }
#else
#define CheckErr(arg) \
    err = arg; \
    if (err != noErr) { \
        HLogErr(err); \
    }
#endif

#ifdef __IPHONE_6_0
#define IPHONE_6_OR_LATER \
    [[UIDevice currentDevice].systemVersion compare:@"6.0"] >= NSOrderedDescending
#else
#define IPHONE_6_OR_LATER NO
#endif

typedef struct HSUAudioStreamDescription {
    double bitrate;
    double duration;
    UInt64 dataByteCount;
    NSUInteger contentLength;
    AudioFormatPropertyID formateID;
    UInt32 channels;
    Float64 sampleRate;
} HSUAudioStreamDescription;

typedef NS_ENUM (NSUInteger, HSUAudioStreamPlayBackState) {
    HSU_AS_STOPPED,
    HSU_AS_WAITTING,
    HSU_AS_PLAYING,
    HSU_AS_PAUSED,
    HSU_AS_FINISHED,
    HSU_AS_ERROR,
};

// As default: buffer memory = kMaxBufferSize * kMaxBufferQueueSize
#define kMaxBufferSize 2048
#define kMaxBufferQueueSize 10
#define kMinBufferQueueSize 3

NSString *stateText(HSUAudioStreamPlayBackState state);

@protocol HSUAudioCacheFileEncryptor;
@interface HSUAudioStreamPlayer : NSObject

@property (readonly) HSUAudioStreamDescription streamDesc;
@property (readonly) double bitrate;
@property (readonly) HSUAudioStreamPlayBackState state;
@property (nonatomic, assign) BOOL useSoftwareCodec;
@property (nonatomic, assign) BOOL enableLevelMetering;
@property (nonatomic, copy) NSString *audioSessionCategory;
@property (nonatomic, assign) AudioFileTypeID fileType;

@property (nonatomic, assign) double presetDuration;

// Bytes, kMinBufferQueueSize * kMaxBufferSize ~ kMaxBufferQueueSize * kMaxBufferSize
// Audio will start playing when buffer is filled or file ended/errored.
// So, change bufferByteSize can change use's waiting time.
@property (nonatomic, assign) NSUInteger bufferByteSize;
// dynamic compute bufferByteSize base on audio bitrate
// use greater byteSize between bufferAudioLength and bufferByteSize
@property (nonatomic, assign) double bufferAudioSeconds;

@property (nonatomic, assign) BOOL enableBlueTooth;
@property (nonatomic, assign) BOOL enableHeadset;
@property (nonatomic, assign) BOOL correctBitrate;
@property (nonatomic, strong) id<HSUAudioCacheFileEncryptor> cacheEncryptor;

@property (nonatomic, assign) NSUInteger dataOffset;

/*!
 * @description
 * initialize player
 *
 * @param url
 * audio url, support HTTP.
 *
 * @pram cacheFilePath
 * cache file path, read/write audio data downloaded.
 *
 * if url != nil and cacheFilePath != nil,
 * then first read data from cache, if no cache, read from url,
 * and save data to cache file at the same time.
 *
 * File cache save supports fragments,
 * using meta file cache/file/path.meta to record downloaded segments.
 *
 * if url != nil and cacheFilePath == nil,
 * then read from url, do not save data to cache file.
 *
 * if url == nil and cacheFilePath != nil,
 * then read from cache file, cache file is assumed a who audio file.
 */
- (instancetype)initWithURL:(NSURL *)url
              cacheFilePath:(NSString *)cacheFilePath;

/* start or resume playing */
- (void)play;
- (void)stop;
- (void)pause;
- (void)seekToTime:(double)time;
- (double)currentTime;
- (double)progress;
- (double)duration;
- (float)currentVolume;

@end