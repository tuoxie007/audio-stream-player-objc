//
//  AudioStreamPlayer.h
//  AudioStreamPlayer
//
//  Created by Jason Hsu on 13/8/14.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#define HSUAudioStreamPlayerStateChanged (@"HSUAudioStreamPlayerStateChanged")


#ifdef DEBUG
#define LOG_LINENUMBER_METHOD(s,...) NSLog((@"[Line %d] %s " s), __LINE__,__PRETTY_FUNCTION__, ##__VA_ARGS__);
#define Log(s,...) LOG_LINENUMBER_METHOD(s,##__VA_ARGS__)
#else
#define Log(s,...)
#endif

#define CheckErr(arg) \
    err = arg; \
    if (err != noErr) { \
        NSLog(@"Error %d, %c%c%c%c", \
                (int)err, \
                ((char *)&err)[3], \
                ((char *)&err)[2], \
                ((char *)&err)[1], \
                ((char *)&err)[0]); \
        abort(); \
    }


typedef struct HSUAudioStreamDescription {
    double bitrate;
    double duration;
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

NSString *stateText(HSUAudioStreamPlayBackState state);

@interface HSUAudioStreamPlayer : NSObject

@property (readonly) HSUAudioStreamDescription streamDesc;
@property (readonly) HSUAudioStreamPlayBackState state;
@property (nonatomic, assign) BOOL useSoftwareCodec;
@property (nonatomic, assign) BOOL enableLevelMetering;
@property (nonatomic, copy) NSString *audioSessionCategory;
@property (nonatomic, assign) NSUInteger bufferByteSize; // bytes, 3 ~ 300

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