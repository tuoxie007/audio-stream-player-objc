//
//  HSUAudioCacheControl.h
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface HSUAudioCacheControl : NSObject

@property (nonatomic, assign) NSUInteger contentLength;

- (instancetype)initWithCacheFilePath:(NSString *)cacheFilePath
                              useMeta:(BOOL)useMeta;

- (NSData *)readCacheFromOffset:(NSUInteger)fromOffset
                      maxLength:(NSUInteger)maxLength
                          error:(BOOL *)error;

- (void)writeCacheData:(NSData *)cacheData
            fromOffset:(NSUInteger)fromOffset;

- (void)updateMetaWithContentLength:(NSUInteger)contentLength;

+ (BOOL)isCacheCompletedForCachePath:(NSString *)cachePath;

@end
