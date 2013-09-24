//
//  HSUAudioDataProvider.m
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import "HSUAudioDataProvider.h"
#import "HSUAudioNetworkControl.h"
#import "HSUAudioCacheControl.h"
#import "HSUAudioStreamPlayer.h"

@implementation HSUAudioDataProvider
{
    HSUAudioNetworkControl *_networkControl;
    HSUAudioCacheControl *_cacheControl;
    NSURL *_url;
    NSData *_swap;
    NSString *_cacheFilePath;
    NSUInteger _byteOffset;
}

- (void)dealloc
{
    _networkControl = nil;
    _cacheControl = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (instancetype)initWithURL:(NSURL *)url
              cacheFilePath:(NSString *)cacheFilePath
                 byteOffset:(NSUInteger)byteOffset
{
    self = [super init];
    if (self) {
        _url = url;
        _byteOffset = byteOffset;
        _startOffset = byteOffset;
        _cacheFilePath = [cacheFilePath copy];
    }
    return self;
}

- (NSData *)readBufferWithMaxLength:(NSUInteger)maxLength error:(BOOL *)error
{
    if (self.contentLength && self.contentLength <= _byteOffset) {
        return nil;
    }
    if (_cacheFilePath && !_cacheControl) {
        _cacheControl = [[HSUAudioCacheControl alloc]
                         initWithCacheFilePath:_cacheFilePath
                         useMeta:_url != nil];
        _cacheControl.encryptor = self.cacheEncryptor;
    }
    if (_cacheControl.contentLength && _cacheControl.contentLength <= _byteOffset) {
        return nil;
    }
    NSData *buffer = [_cacheControl readCacheFromOffset:_byteOffset
                                              maxLength:maxLength
                                                  error:error];
    
    if (buffer.length == 0) {
        if (!_networkControl && _url) {
            // notify data wait if start read data from network
            [[NSNotificationCenter defaultCenter]
             postNotificationName:HSUAudioStreamDataWait
             object:self];
            _networkControl = [[HSUAudioNetworkControl alloc]
                               initWithURL:_url
                               byteOffset:_byteOffset];
        }
        buffer = [_networkControl readDataWithMaxLength:maxLength
                                                  error:error];
        if (buffer.length) {
            [_cacheControl writeCacheData:buffer
                               fromOffset:_byteOffset];
        } else if (_byteOffset < self.contentLength) {
            *error = YES;
        }
//        HLog(@"read network %u, %u", _byteOffset/1024, buffer.length);
    } else {
        _networkControl = nil;
//        HLog(@"read cache %u, %u", _byteOffset/1024, buffer.length);
    }
    _byteOffset += buffer.length;
    
    // simulate slowly download
//    NSLog(@"read bytes %u", _byteOffset/1000);
//    if (_byteOffset > 1000*1000) {
//    } else if (_byteOffset > 1000*500) {
//        [NSThread sleepForTimeInterval:0.1];
//    }
    return buffer;
}

- (void)close
{
    [_networkControl close];
}

- (NSUInteger)contentLength
{
    NSUInteger len = 0;
    if ((len = _cacheControl.contentLength)) {
        return len;
    }
    len = _networkControl.contentLength;
    [_cacheControl updateMetaWithContentLength:len];
    return len;
}

@end
