//
//  HSUAudioCacheControl.h
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol HSUAudioCacheFileEncryptor;

@interface HSUAudioCacheControl : NSObject

@property (nonatomic, assign) NSUInteger contentLength;
@property (nonatomic, weak) id<HSUAudioCacheFileEncryptor> encryptor;

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


@protocol HSUAudioCacheFileEncryptor <NSObject>

- (void)encryptFileWith:(NSString *)filePath;
- (NSData *)encryptData:(NSData *)data;
- (NSData *)decryptData:(NSData *)data;

@end

@interface HSUDefaultAudioCacheFileEncryptor : NSObject <HSUAudioCacheFileEncryptor>

@end