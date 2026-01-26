#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <AVKit/AVKit.h>

API_AVAILABLE(ios(15.0))
@interface FlutterRTCPipController : NSObject <RTCVideoRenderer, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>

- (instancetype)initWithVideoTrack:(RTCVideoTrack *)videoTrack;
@property(nonatomic, assign) BOOL mirror;
- (BOOL)prepare;
- (BOOL)start;
- (void)stop;
- (BOOL)isActive;
+ (BOOL)isPictureInPictureSupported;

@end
