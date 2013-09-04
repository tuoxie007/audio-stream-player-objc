//
//  HSUAudioDataProvider.h
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <Foundation/Foundation.h>

#define HSUAudioStreamDataWait (@"HSUAudioStreamDataWait")

@protocol HSUAudioCacheFileEncryptor;
@interface HSUAudioDataProvider : NSObject

@property (nonatomic, readonly) NSUInteger startOffset;
@property (nonatomic, readonly) NSUInteger contentLength;
@property (nonatomic, weak) id<HSUAudioCacheFileEncryptor> cacheEncryptor;

- (instancetype)initWithURL:(NSURL *)url
              cacheFilePath:(NSString *)cacheFilePath
                 byteOffset:(NSUInteger)byteOffset;

- (NSData *)readBufferWithMaxLength:(NSUInteger)maxLength error:(BOOL *)error;

- (void)close;

@end
