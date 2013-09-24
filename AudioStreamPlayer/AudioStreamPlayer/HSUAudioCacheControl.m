//
//  HSUAudioCacheControl.m
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import "HSUAudioCacheControl.h"
#import "HSUAudioStreamPlayer.h"

@interface HSUAudioCacheMeta : NSObject

@property (nonatomic, strong) NSMutableArray *ranges;
@property (nonatomic, strong) NSNumber *contentLength;

@end

@implementation HSUAudioCacheMeta

- (void)updateRangeWithStartOffset:(NSUInteger)startOffset
                            length:(NSUInteger)length
{
    BOOL found = NO;
    for (int i=0; i<self.ranges.count; i++) {
        NSArray *range = self.ranges[i];
        NSUInteger rangeStart = [range[0] unsignedIntegerValue];
        NSUInteger rangeEnd = [range[1] unsignedIntegerValue];
        if (rangeStart == startOffset + length) { // left
            self.ranges[i] = @[@(startOffset), @(rangeEnd)];
            found = YES;
        } else if (rangeEnd == startOffset) { // right
            self.ranges[i] = @[@(rangeStart), @(startOffset + length)];
            found = YES;
        }
    }
    if (!found) {
        [self.ranges addObject:@[@(startOffset), @(startOffset + length)]];
    }
}

- (void)writeToFile:(NSString *)filePath
{
    if (!filePath) return;
    
    [self.ranges sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSArray *a1 = obj1;
        NSArray *a2 = obj2;
        return [a1[0] compare:a2[0]];
    }];
    NSArray *preRange = nil;
    NSArray *curRange = nil;
    for (int i=1; i<self.ranges.count; ) {
        preRange = self.ranges[i-1];
        curRange = self.ranges[i];
        if ([curRange[0] unsignedIntegerValue] >= [preRange[0] unsignedIntegerValue] &&
            [curRange[1] unsignedIntegerValue] >= [preRange[1] unsignedIntegerValue] &&
            [curRange[0] unsignedIntegerValue] <= [preRange[1] unsignedIntegerValue]) {
            [self.ranges removeObject:preRange];
            [self.ranges removeObject:curRange];
            [self.ranges insertObject:@[preRange[0], curRange[1]] atIndex:i-1];
            continue;
        }
        i++;
    }
    NSMutableDictionary *dict =
    [NSMutableDictionary dictionaryWithCapacity:2];
    dict[@"Content-Length"] = self.contentLength;
    dict[@"ranges"] = self.ranges;
    [[NSJSONSerialization
      dataWithJSONObject:dict
      options:0
      error:nil]
     writeToFile:filePath atomically:YES];
}

+ (instancetype)readFromFile:(NSString *)filePath
{
    if (!filePath) return nil;
    
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) return nil;
    NSDictionary *dict = [NSJSONSerialization
                          JSONObjectWithData:data
                          options:0
                          error:nil];
    HSUAudioCacheMeta *meta = [[HSUAudioCacheMeta alloc] init];
    meta.contentLength = @([dict[@"Content-Length"] unsignedIntegerValue]);
    meta.ranges = [dict[@"ranges"] mutableCopy];
    if (!meta.ranges) {
        meta.ranges = [NSMutableArray arrayWithCapacity:1];
    }
    return meta;
}

@end

@implementation HSUAudioCacheControl
{
    NSString *_cacheFilePath;
    NSString *_metaFilePath;
    HSUAudioCacheMeta *_meta;
    NSFileHandle *_writer;
    NSFileHandle *_reader;
    BOOL _useMeta;
}

- (void)dealloc
{
    [_meta writeToFile:_metaFilePath];
    [_reader closeFile];
    [_writer closeFile];
}

- (instancetype)initWithCacheFilePath:(NSString *)cacheFilePath
                              useMeta:(BOOL)useMeta
{
    self = [super init];
    if (self) {
        _cacheFilePath = [cacheFilePath copy];
        _useMeta = useMeta;
        
        if (_useMeta) {
            _metaFilePath = [[NSString stringWithFormat:@"%@.meta", cacheFilePath] copy];
            
            if (![[NSFileManager defaultManager] fileExistsAtPath:_cacheFilePath]) {
                BOOL succ = [[NSFileManager defaultManager]
                             createFileAtPath:_cacheFilePath
                             contents:nil
                             attributes:nil];
                if (!succ) {
                    HLog(@"create cache file failed %@", _cacheFilePath);
                }
            }
            if (![[NSFileManager defaultManager] fileExistsAtPath:_metaFilePath]) {
                BOOL succ = [[NSFileManager defaultManager]
                             createFileAtPath:_metaFilePath
                             contents:nil
                             attributes:nil];
                if (!succ) {
                    HLog(@"create cache file failed %@", _metaFilePath);
                }
            }
            _meta = [HSUAudioCacheMeta readFromFile:_metaFilePath];
        } else {
            NSAssert([[NSFileManager defaultManager] fileExistsAtPath:_cacheFilePath],
                     @"cache file not existed");
            NSDictionary *fileAttributes = [[NSFileManager defaultManager]
                                            attributesOfItemAtPath:_cacheFilePath
                                            error:nil];
            _contentLength = [[fileAttributes objectForKey:NSFileSize]
                              unsignedIntegerValue];
        }
    }
    return self;
}

- (NSData *)readCacheFromOffset:(NSUInteger)fromOffset
                      maxLength:(NSUInteger)maxLength
                          error:(BOOL *)error
{
    NSData *data = nil;
    if (!_reader) {
        _reader = [NSFileHandle fileHandleForReadingAtPath:_cacheFilePath];
    }
    if (_useMeta) {
        for (NSArray *aRange in _meta.ranges) {
            NSUInteger startOffset = [aRange[0] unsignedIntegerValue];
            NSUInteger endOffset = [aRange[1] unsignedIntegerValue];
            
            if (startOffset <= fromOffset && endOffset > fromOffset) {
                [_reader seekToFileOffset:fromOffset];
                data = [_reader readDataOfLength:MIN(maxLength, endOffset - fromOffset)];
                break;
            }
        }
    } else {
        [_reader seekToFileOffset:fromOffset];
        data = [_reader readDataOfLength:maxLength];
    }
    if (self.encryptor) {
        data = [self.encryptor decryptData:data];
    }
    return data;
}

- (void)writeCacheData:(NSData *)cacheData
            fromOffset:(NSUInteger)fromOffset
{
    if (!_writer) {
        _writer = [NSFileHandle fileHandleForUpdatingAtPath:_cacheFilePath];
    }
    [_writer seekToFileOffset:fromOffset];
    if (self.encryptor) {
        cacheData = [self.encryptor encryptData:cacheData];
    }
    [_writer writeData:cacheData];
    [self _updateRangesFromOffset:fromOffset
                           length:cacheData.length];
}

- (void)_updateRangesFromOffset:(NSUInteger)fromOffset length:(NSUInteger)length
{
    [_meta updateRangeWithStartOffset:fromOffset
                               length:length];
}

- (void)updateMetaWithContentLength:(NSUInteger)contentLength
{
    _contentLength = contentLength;
    _meta.contentLength = @(_contentLength);
    [_meta writeToFile:_metaFilePath];
}

- (NSUInteger)contentLength
{
    if (_contentLength) {
        return _contentLength;
    }
    return [_meta.contentLength unsignedIntegerValue];
}

+ (BOOL)isCacheCompletedForCachePath:(NSString *)cachePath
{
    NSString *metaPath = [NSString stringWithFormat:@"%@.meta", cachePath];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:cachePath]) {
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:metaPath]) {
        return NO;
    }
    HSUAudioCacheMeta *meta = [HSUAudioCacheMeta readFromFile:metaPath];
    if (meta.ranges.count != 1) {
        return NO;
    }
    return [meta.ranges[0][1] unsignedIntegerValue] ==
            [meta.contentLength unsignedIntegerValue];
}

@end

@implementation HSUDefaultAudioCacheFileEncryptor

- (void)encryptFileWith:(NSString *)filePath
{
	NSString *desFilepath = [filePath stringByAppendingString:@"encodeFile"];
    
	NSFileManager *fm = [[NSFileManager alloc] init];
	[fm createFileAtPath:desFilepath contents:nil attributes:nil];
    
	NSFileHandle *readFileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
	NSFileHandle *writeFileHandle = [NSFileHandle fileHandleForUpdatingAtPath:desFilepath];
	
    while (YES) {
		@autoreleasepool {
			NSData *data = [readFileHandle readDataOfLength:4096];
            if (!data.length) {
                break;
            }
			data = [self encryptData:data];
			[writeFileHandle writeData:data];
		}
	}
	
	[writeFileHandle closeFile];
	[readFileHandle closeFile];
	[fm removeItemAtPath:filePath error:nil];
	[fm moveItemAtPath:desFilepath toPath:filePath error:nil];
}


-(NSData *)encryptData:(NSData *)data
{
    if (data.length == 0) {
        return data;
    }
    UInt8 *bytes = (UInt8 *)malloc(data.length);
    for (int i=0; i<data.length; i++) {
        bytes[i] = ((UInt8 *)data.bytes)[i] ^ HSUDefaultAudioCacheFileEncryptorPassword;
    }
    NSData *result = [NSData dataWithBytes:bytes length:data.length];
    free(bytes);
    return result;
}

-(NSData *)decryptData:(NSData *)data
{
    return [self encryptData:data];
}

@end