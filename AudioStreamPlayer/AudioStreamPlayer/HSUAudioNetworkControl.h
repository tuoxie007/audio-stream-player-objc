//
//  HSUAudioNetworkControl.h
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import <Foundation/Foundation.h>

#define NETWORK_TIMEOUT 60

@interface HSUAudioNetworkControl : NSObject

@property (nonatomic, assign) NSUInteger contentLength;

- (instancetype)initWithURL:(NSURL *)url
                 byteOffset:(NSUInteger)byteOffset;

- (NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                            error:(BOOL *)error;

- (void)close;

@end
