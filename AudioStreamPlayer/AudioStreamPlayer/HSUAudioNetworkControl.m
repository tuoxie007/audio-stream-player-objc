//
//  HSUAudioNetworkControl.m
//  HSUAudioStream
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import "HSUAudioNetworkControl.h"
#import <CFNetwork/CFNetwork.h>
#include <pthread.h>
#include <sys/time.h>

void HSUReadStreamCallBack(CFReadStreamRef   stream,
                           CFStreamEventType type,
                           void *            clientCallBackInfo);

@implementation HSUAudioNetworkControl
{
    NSUInteger _byteOffset;
    CFReadStreamRef _stream;
    pthread_cond_t _cond;
    pthread_mutex_t _mutex;
    CFStreamEventType _streamEvent;
    NSDictionary *_httpHeaders;
    BOOL _closed;
}

- (void)dealloc
{
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
    CFReadStreamClose(_stream);
    CFRelease(_stream);
    _stream = nil;
}

- (instancetype)initWithURL:(NSURL *)url
                 byteOffset:(NSUInteger)byteOffset
{
    self = [super init];
    if (self) {
        _closed = YES;
		CFHTTPMessageRef message =
        CFHTTPMessageCreateRequest(NULL,
                                   (CFStringRef)@"GET",
                                   (__bridge CFURLRef)url,
                                   kCFHTTPVersion1_1);
        _byteOffset = byteOffset;
        if (_byteOffset) {
            NSString *range = [NSString stringWithFormat:@"bytes=%u-", _byteOffset];
			CFHTTPMessageSetHeaderFieldValue(message,
                                             CFSTR("Range"),
                                             (__bridge CFStringRef)range);
        }
        _stream = CFReadStreamCreateForHTTPRequest(NULL, message);
        CFRelease(message);
        
        if (CFReadStreamSetProperty(_stream,
                                    kCFStreamPropertyHTTPShouldAutoredirect,
                                    kCFBooleanTrue) == false) {
            // todo error
		}
        
        
		// Handle proxies
		CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
		CFReadStreamSetProperty(_stream,
                                kCFStreamPropertyHTTPProxy,
                                proxySettings);
		CFRelease(proxySettings);
		
        
		// Handle SSL connections
		if( [[url absoluteString] rangeOfString:@"https"].location != NSNotFound) {
			NSMutableDictionary *sslSettings = [NSMutableDictionary dictionary];
            sslSettings[(NSString *)kCFStreamSSLLevel] = (NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL;
            sslSettings[(NSString *)kCFStreamSSLAllowsExpiredCertificates] = @(YES);
            sslSettings[(NSString *)kCFStreamSSLAllowsExpiredRoots] = @(YES);
            sslSettings[(NSString *)kCFStreamSSLAllowsAnyRoot] = @(YES);
            sslSettings[(NSString *)kCFStreamSSLValidatesCertificateChain] = @(NO);
            sslSettings[(NSString *)kCFStreamSSLPeerName] = [NSNull null];
			CFReadStreamSetProperty(_stream,
                                    kCFStreamPropertySSLSettings,
                                    (__bridge CFDictionaryRef)sslSettings);
		}
        
        if (!CFReadStreamOpen(_stream)) {
			CFRelease(_stream);
            // todo error
		}
        _closed = NO;
		CFStreamClientContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
		CFReadStreamSetClient(_stream,
                              kCFStreamEventHasBytesAvailable |
                              kCFStreamEventErrorOccurred |
                              kCFStreamEventEndEncountered,
                              HSUReadStreamCallBack,
                              &context);
		CFReadStreamScheduleWithRunLoop(_stream,
                                        CFRunLoopGetMain(),
                                        kCFRunLoopCommonModes);
        
        pthread_mutex_init(&_mutex, NULL);
        pthread_cond_init(&_cond, NULL);
    }
    return self;
}

- (NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                            error:(BOOL *)error
{
    int               rc;
    struct timespec   ts;
    struct timeval    tp;
    
    rc = pthread_mutex_lock(&_mutex);
    rc = gettimeofday(&tp, NULL);
    
    /* Convert from timeval to timespec */
    ts.tv_sec  = tp.tv_sec;
    ts.tv_nsec = tp.tv_usec * 1000;
    ts.tv_sec += NETWORK_TIMEOUT;
    
    while (!_closed && _streamEvent == kCFStreamEventNone && !CFReadStreamHasBytesAvailable(_stream)) {
        int status = pthread_cond_timedwait(&_cond, &_mutex, &ts);
        if (status != 0) {
            pthread_mutex_unlock(&_mutex);
            return nil;
        } else if (status == ETIMEDOUT) {
            pthread_mutex_unlock(&_mutex);
            return nil;
        }
    }
    
    if (_closed) {
        pthread_mutex_unlock(&_mutex);
        return nil;
    }
    
    if (_streamEvent == kCFStreamEventEndEncountered) {
        pthread_mutex_unlock(&_mutex);
        return nil;
    }
    
    if (_streamEvent == kCFStreamEventErrorOccurred) {
        *error = YES;
        pthread_mutex_unlock(&_mutex);
        return nil;
    }
    
    UInt8 *buffer = (UInt8 *)malloc(maxLength);
    long len = CFReadStreamRead(_stream, buffer, maxLength);
    static long total = 0;
    total += len;
    _streamEvent = kCFStreamEventNone;
    
    pthread_mutex_unlock(&_mutex);
    
    if (len == 0) {
        return nil;
    } else if (len < 0) {
        // todo error
        return nil;
    }
    
    if (!_httpHeaders) {
        CFTypeRef message =
        CFReadStreamCopyProperty(_stream, kCFStreamPropertyHTTPResponseHeader);
        _httpHeaders = (__bridge_transfer NSDictionary *)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)message);
        CFRelease(message);
        
        _contentLength = [[_httpHeaders objectForKey:@"Content-Length"] integerValue] + _byteOffset;
    }
    
    NSData *data = [NSData dataWithBytes:buffer length:len];
    free(buffer);
    return data;
}

- (void)streamStateChanged:(CFReadStreamRef)stream
                 eventType:(CFStreamEventType)eventType
{
    pthread_mutex_lock(&_mutex);
    _streamEvent = eventType;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

- (void)close
{
    pthread_mutex_lock(&_mutex);
    _closed = YES;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

@end

void HSUReadStreamCallBack(CFReadStreamRef   stream,
                           CFStreamEventType type,
                           void *            clientCallBackInfo)
{
    HSUAudioNetworkControl *networkControl = (__bridge HSUAudioNetworkControl *)clientCallBackInfo;
    [networkControl streamStateChanged:stream
                             eventType:type];
}
