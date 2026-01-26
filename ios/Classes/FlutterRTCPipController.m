#import "FlutterRTCPipController.h"

#import <UIKit/UIKit.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/RTCYUVHelper.h>

#import "FlutterRTCFrameCapturer.h"

@implementation FlutterRTCPipController {
  RTCVideoTrack *_videoTrack;
  AVSampleBufferDisplayLayer *_displayLayer;
  AVPictureInPictureController *_pipController;
  UIView *_pipView;
  CMVideoFormatDescriptionRef _formatDescription;
  CMTimebaseRef _timebase;
  CGSize _lastFrameSize;
  BOOL _isPlaying;
  BOOL _isRendererAttached;
  dispatch_queue_t _frameQueue;
}

- (instancetype)initWithVideoTrack:(RTCVideoTrack *)videoTrack {
  self = [super init];
  if (self) {
    _videoTrack = videoTrack;
    _isPlaying = YES;
    _lastFrameSize = CGSizeZero;
    _frameQueue = dispatch_queue_create("flutter.webrtc.pip.frames", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

+ (BOOL)isPictureInPictureSupported {
  if (@available(iOS 15.0, *)) {
    return [AVPictureInPictureController isPictureInPictureSupported];
  }
  return NO;
}

- (BOOL)isActive {
  return _pipController != nil && _pipController.isPictureInPictureActive;
}

- (BOOL)start {
  if (@available(iOS 15.0, *)) {
    if (![self prepare]) {
      return NO;
    }

    if (!_pipController.isPictureInPictureActive) {
      [_pipController startPictureInPicture];
    }
    return YES;
  }
  return NO;
}

- (BOOL)prepare {
  if (@available(iOS 15.0, *)) {
    if (![FlutterRTCPipController isPictureInPictureSupported]) {
      return NO;
    }
    if (_videoTrack == nil) {
      return NO;
    }
    [self setupDisplayLayerIfNeeded];
    [self setupPipControllerIfNeeded];
    if (_pipController == nil) {
      return NO;
    }
    if (!_isRendererAttached) {
      [_videoTrack addRenderer:self];
      _isRendererAttached = YES;
    }
    return YES;
  }
  return NO;
}

- (void)stop {
  if (@available(iOS 15.0, *)) {
    if (_videoTrack) {
      if (_isRendererAttached) {
        [_videoTrack removeRenderer:self];
        _isRendererAttached = NO;
      }
      _videoTrack = nil;
    }

    if (_pipController && _pipController.isPictureInPictureActive) {
      [_pipController stopPictureInPicture];
    }
    _pipController = nil;

    if (_displayLayer) {
      [_displayLayer flushAndRemoveImage];
      [_displayLayer removeFromSuperlayer];
    }
    _displayLayer = nil;

    if (_pipView) {
      [_pipView removeFromSuperview];
      _pipView = nil;
    }

    if (_formatDescription) {
      CFRelease(_formatDescription);
      _formatDescription = nil;
    }

    if (_timebase) {
      CFRelease(_timebase);
      _timebase = nil;
    }
  }
}

- (void)setupDisplayLayerIfNeeded {
  if (_displayLayer != nil) {
    return;
  }

  _displayLayer = [AVSampleBufferDisplayLayer new];
  _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  _displayLayer.backgroundColor = [UIColor blackColor].CGColor;
  _displayLayer.frame = CGRectMake(0, 0, 1, 1);

  CMTimebaseRef timebase = NULL;
  if (CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase) == noErr) {
    CMTimebaseSetTime(timebase, CMTimeMake(0, 1));
    CMTimebaseSetRate(timebase, 1.0);
    _displayLayer.controlTimebase = timebase;
    _timebase = timebase;
  }

  UIView *hostView = [self hostView];
  if (hostView) {
    _pipView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    _pipView.backgroundColor = [UIColor clearColor];
    _pipView.userInteractionEnabled = NO;
    _pipView.accessibilityElementsHidden = YES;
    _pipView.isAccessibilityElement = NO;
    _pipView.alpha = 0.01;
    [hostView addSubview:_pipView];
    [_pipView.layer addSublayer:_displayLayer];
  } else {
    NSLog(@"FlutterRTCPipController: hostView is nil; PiP view not attached");
  }
}

- (void)setupPipControllerIfNeeded API_AVAILABLE(ios(15.0)) {
  if (_pipController != nil || _displayLayer == nil) {
    return;
  }

  AVPictureInPictureControllerContentSource *source =
      [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:_displayLayer
                                                                          playbackDelegate:self];
  _pipController = [[AVPictureInPictureController alloc] initWithContentSource:source];
  _pipController.delegate = self;
  if (@available(iOS 14.2, *)) {
    _pipController.canStartPictureInPictureAutomaticallyFromInline = true;
  }
}

- (UIView *)hostView {
  UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
  if (!keyWindow) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
      if (window.isKeyWindow) {
        keyWindow = window;
        break;
      }
    }
  }
  if (!keyWindow) {
    if (@available(iOS 13.0, *)) {
      for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) {
          continue;
        }
        if (![scene isKindOfClass:[UIWindowScene class]]) {
          continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
          if (window.isKeyWindow) {
            keyWindow = window;
            break;
          }
        }
        if (keyWindow) {
          break;
        }
      }
    }
  }
  if (!keyWindow) {
    id<UIApplicationDelegate> appDelegate = UIApplication.sharedApplication.delegate;
    if ([appDelegate respondsToSelector:@selector(window)]) {
      keyWindow = appDelegate.window;
    }
  }
  if (!keyWindow) {
    keyWindow = UIApplication.sharedApplication.windows.firstObject;
  }
  if (!keyWindow || !keyWindow.rootViewController) {
    return nil;
  }
  return keyWindow.rootViewController.view;
}

#pragma mark - RTCVideoRenderer

- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(RTCVideoFrame *)frame {
  if (frame == nil || _displayLayer == nil) {
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(_frameQueue, ^{
    __strong typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_displayLayer == nil) {
      return;
    }

    CVPixelBufferRef pixelBuffer = [strongSelf copyPixelBufferFromFrame:frame];
    if (pixelBuffer == nil) {
      return;
    }

    CMSampleBufferRef sampleBuffer = [strongSelf sampleBufferFromPixelBuffer:pixelBuffer
                                                                 timeStampNs:frame.timeStampNs];

    if (sampleBuffer != nil) {
      if (strongSelf->_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [strongSelf->_displayLayer flush];
      }
      if (strongSelf->_displayLayer.isReadyForMoreMediaData) {
        [strongSelf->_displayLayer enqueueSampleBuffer:sampleBuffer];
      }
      CFRelease(sampleBuffer);
    }

    CVPixelBufferRelease(pixelBuffer);
  });
}

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotatedWidth = src.width;
  int rotatedHeight = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotatedWidth;
    rotatedWidth = rotatedHeight;
    rotatedHeight = temp;
  }

  id<RTCI420Buffer> buffer = [[RTCI420Buffer alloc] initWithWidth:rotatedWidth
                                                           height:rotatedHeight];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t *)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t *)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t *)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

static void mirrorBGRA(uint8_t *baseAddress, size_t width, size_t height, size_t bytesPerRow) {
  const size_t bytesPerPixel = 4;
  const size_t rowBytes = width * bytesPerPixel;
  for (size_t y = 0; y < height; y++) {
    uint8_t *row = baseAddress + (y * bytesPerRow);
    size_t left = 0;
    size_t right = rowBytes - bytesPerPixel;
    while (left < right) {
      for (size_t i = 0; i < bytesPerPixel; i++) {
        uint8_t tmp = row[left + i];
        row[left + i] = row[right + i];
        row[right + i] = tmp;
      }
      left += bytesPerPixel;
      right -= bytesPerPixel;
    }
  }
}

- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTCVideoFrame *)frame {
  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];
  size_t width = (size_t)roundf(i420Buffer.width);
  size_t height = (size_t)roundf(i420Buffer.height);

  NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferRef outputPixelBuffer = nil;
  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width,
                                        height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes,
                                        &outputPixelBuffer);
  if (status != kCVReturnSuccess || outputPixelBuffer == nil) {
    return nil;
  }

  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);
  uint8_t *dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
  const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

  // Match FlutterRTCVideoRenderer: kCVPixelFormatType_32BGRA expects ARGB in libyuv.
  [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                srcStrideY:i420Buffer.strideY
                      srcU:i420Buffer.dataU
                srcStrideU:i420Buffer.strideU
                      srcV:i420Buffer.dataV
                srcStrideV:i420Buffer.strideV
                   dstARGB:dst
             dstStrideARGB:(int)bytesPerRow
                     width:i420Buffer.width
                    height:i420Buffer.height];

  if (_mirror) {
    mirrorBGRA(dst, width, height, bytesPerRow);
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
  return outputPixelBuffer;
}

- (CMSampleBufferRef)sampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                     timeStampNs:(int64_t)timeStampNs {
  if (pixelBuffer == nil) {
    return nil;
  }

  const size_t width = CVPixelBufferGetWidth(pixelBuffer);
  const size_t height = CVPixelBufferGetHeight(pixelBuffer);
  if (!CGSizeEqualToSize(_lastFrameSize, CGSizeMake(width, height))) {
    _lastFrameSize = CGSizeMake(width, height);
    if (_formatDescription) {
      CFRelease(_formatDescription);
      _formatDescription = nil;
    }
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                 pixelBuffer,
                                                 &_formatDescription);
  }

  if (_formatDescription == nil) {
    return nil;
  }

  CMTime presentationTime = CMTimebaseGetTime(_timebase);
  if (timeStampNs > 0) {
    presentationTime = CMTimeMake(timeStampNs, 1000000000);
  }

  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, 30),
      .presentationTimeStamp = presentationTime,
      .decodeTimeStamp = kCMTimeInvalid,
  };

  CMSampleBufferRef sampleBuffer = nil;
  CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                           pixelBuffer,
                                           _formatDescription,
                                           &timing,
                                           &sampleBuffer);
  if (sampleBuffer == nil) {
    return nil;
  }

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFMutableDictionaryRef attachment =
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  }

  return sampleBuffer;
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                        setPlaying:(BOOL)playing {
  _isPlaying = playing;
  [pictureInPictureController invalidatePlaybackState];
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)pictureInPictureController {
  if (_displayLayer == nil) {
    return kCMTimeRangeInvalid;
  }
  return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)pictureInPictureController {
  return !_isPlaying;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
            didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
  NSLog(@"FlutterRTCPipController: failed to start PiP: %@", error);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
  if (completionHandler) {
    completionHandler();
  }
}

@end
