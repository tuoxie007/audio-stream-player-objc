//
//  HSUViewController.m
//  HSUAudioStreamExample
//
//  Created by Jason Hsu on 13/8/4.
//  Copyright (c) 2013年 Jason Hsu. All rights reserved.
//

#import "HSUViewController.h"
#import "AudioStreamPlayer/HSUAudioStreamPlayer.h"
#import <CommonCrypto/CommonDigest.h>
#import <AVFoundation/AVFoundation.h>

#define DOC_FILE(s) [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:s]
NSString *md5Hash (NSString *str);

@interface HSUViewController ()

@property (weak, nonatomic) IBOutlet UITextField *urlTextField;
@property (weak, nonatomic) IBOutlet UISlider *progressSlider;
@property (weak, nonatomic) IBOutlet UILabel *stateLabel;
@property (weak, nonatomic) IBOutlet UILabel *durationLabel;
@property (weak, nonatomic) IBOutlet UIButton *controlButton;
@property (weak, nonatomic) IBOutlet UILabel *currentTimeLabel;

@property (nonatomic, strong) HSUAudioStreamPlayer *player;
@property (nonatomic, weak) NSTimer *progressTimer;

@end

@implementation HSUViewController

- (void)dealloc
{
    [self.progressTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (IBAction)seek:(id)sender {
    UIButton *bnt = sender;
    NSString *text = bnt.titleLabel.text;
    double time = [text doubleValue];
    [self.player seekToTime:time];
}

- (IBAction)stop:(id)sender {
    [self.player stop];
}

- (IBAction)progressDragStarted:(id)sender {
    [self stopProgressMonitor];
}

- (IBAction)progressChanged:(id)sender {
    [self startProgressMonitor];
    UISlider *slider = sender;
    double duration = self.player.duration;
    [self.player seekToTime:slider.value * duration];
}

- (IBAction)controlButon:(id)sender {
    HSUAudioStreamPlayBackState state = self.player.state;
    if (!self.player || state == HSU_AS_STOPPED) {
        NSString *urlString = self.urlTextField.text;
        NSString *urlHash = [NSString stringWithFormat:@"%@.mp3", md5Hash(urlString)];
        NSString *cacheFile = DOC_FILE(urlHash);
        self.player = [[HSUAudioStreamPlayer alloc]
                       initWithURL:[NSURL URLWithString:urlString]
                       cacheFilePath:cacheFile];
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(playBackStateChanged:)
         name:HSUAudioStreamPlayerStateChangedNotification
         object:self.player];
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(playBackDurationChanged:)
         name:HSUAudioStreamPlayerDurationUpdatedNotification
         object:self.player];
        [self.player play];
    }
    else if (state == HSU_AS_PLAYING) {
        [self.player pause];
    }
    else if (state == HSU_AS_WAITTING) {
        [self.player stop];
    }
    else if (state == HSU_AS_PAUSED) {
        [self.player play];
    }
    else if (state == HSU_AS_STOPPED) {
        [self.player play];
    }
    else if (state == HSU_AS_FINISHED) {
        [self.player play];
    }
}

- (void)playBackStateChanged:(NSNotification *)notification
{
    HSUAudioStreamPlayer *player = notification.object;
    HSUAudioStreamPlayBackState state = player.state;
    self.stateLabel.text = stateText(player.state);
    if (state == HSU_AS_PLAYING) {
        self.durationLabel.text = [NSString
                                   stringWithFormat:@"%gs",
                                   ceil(self.player.duration)];
        [self.durationLabel sizeToFit];
        [self.controlButton setTitle:@"Pause" forState:UIControlStateNormal];
        [self startProgressMonitor];
    }
    else if (state == HSU_AS_PAUSED) {
        [self.controlButton setTitle:@"Continue" forState:UIControlStateNormal];
        [self stopProgressMonitor];
    }
    else if (state == HSU_AS_WAITTING) {
        [self.controlButton setTitle:@"Stop" forState:UIControlStateNormal];
        [self startProgressMonitor];
    }
    else if (state == HSU_AS_STOPPED) {
        [self.controlButton setTitle:@"Play" forState:UIControlStateNormal];
        [self updateProgress];
        [self stopProgressMonitor];
    }
    else if (state == HSU_AS_FINISHED) {
        [self.controlButton setTitle:@"Play" forState:UIControlStateNormal];
        [self updateProgress];
        [self stopProgressMonitor];
    }
}

- (void)playBackDurationChanged:(NSNotification *)notification
{
    self.durationLabel.text = [NSString
                               stringWithFormat:@"%gs",
                               ceil(self.player.duration)];
    [self.durationLabel sizeToFit];
}

- (void)startProgressMonitor
{
    [self.progressTimer invalidate];
    self.progressTimer = [NSTimer
                          scheduledTimerWithTimeInterval:0.5
                          target:self
                          selector:@selector(updateProgress)
                          userInfo:nil
                          repeats:YES];
}

- (void)stopProgressMonitor
{
    [self.progressTimer invalidate];
}

- (void)updateProgress
{
    double progress = self.player.progress;
    self.progressSlider.value = progress;
    
    self.currentTimeLabel.text = [NSString
                                  stringWithFormat:@"%gs",
                                  ceil(self.player.currentTime)];
    [self.currentTimeLabel sizeToFit];
}

@end


NSString *md5Hash (NSString *str)
{
    unsigned char result[16];
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    CC_MD5(data.bytes, data.length, result);
    
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11], result[12], result[13], result[14], result[15]
            ];
}
