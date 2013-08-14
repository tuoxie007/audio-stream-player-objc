# Audio Stream Player for Objective-C
## Basic usage
    self.player = [[HSUAudioStreamPlayer alloc]
                   initWithURL:[NSURL URLWithString:@"http://goo.gl/ATX7Ea"]
                   cacheFilePath:nil];
	[self.player play];

## Advanced usages

### Player for HTTP URL
    self.player = [[HSUAudioStreamPlayer alloc]
                   initWithURL:[NSURL URLWithString:urlString]
                   cacheFilePath:cacheFile];

### Player for Local File
    self.player = [[HSUAudioStreamPlayer alloc]
                   initWithURL:nil
                   cacheFilePath:cacheFile];

### Player for HTTP URL with local cache
    self.player = [[HSUAudioStreamPlayer alloc]
                   initWithURL:[NSURL URLWithString:urlString]
                   cacheFilePath:cacheFile];

### Receive state changes
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(playBackStateChanged:)
     name:HSUAudioStreamPlayerStateChanged
     object:self.player];

	- (void)playBackStateChanged:(NSNotification *)notification
	{
    	HSUAudioStreamPlayer *player = notification.object;
	    HSUAudioStreamPlayBackState state = player.state;
	    …
	}
### Controls
    if (state == HSU_AS_STOPPED) {
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
### Seek (use HTTP Range)
    [self.player seekToTime:time];

### Work with recorder
	#import <AVFoundation/AVFoundation.h>
	self.player = ...
    self.player.audioSessionCategory = 
    	AVAudioSessionCategoryPlayAndRecord;
    	// AVAudioSessionCategoryPlayAndRecord as default
    	
	or control category yourself:
    self.player.audioSessionCategory = nil;
    [[AVAudioSession sharedInstance]
     setCategory:AVAudioSessionCategoryPlayAndRecord
     error:nil];


### Retrieve player information
	double duration = self.player.duration;
    double progress = self.player.progress;
	double currentTime = self.player.currentTime;

## And more

