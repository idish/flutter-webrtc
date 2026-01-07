import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track_impl.dart';
import 'utils.dart';

class WebRTCPictureInPicture {
  static Future<bool> isSupported() async {
    if (!WebRTC.platformIsIOS) {
      return false;
    }
    final result = await WebRTC.invokeMethod('pipIsSupported');
    return result == true;
  }

  static Future<bool> start(MediaStreamTrack track) async {
    if (!WebRTC.platformIsIOS) {
      return false;
    }
    final peerConnectionId =
        track is MediaStreamTrackNative ? track.peerConnectionId : null;
    final result = await WebRTC.invokeMethod('pipStart', <String, dynamic>{
      'trackId': track.id,
      'peerConnectionId': peerConnectionId,
    });
    return result == true;
  }

  static Future<bool> stop() async {
    if (!WebRTC.platformIsIOS) {
      return false;
    }
    final result = await WebRTC.invokeMethod('pipStop');
    return result == true;
  }

  static Future<bool> isActive() async {
    if (!WebRTC.platformIsIOS) {
      return false;
    }
    final result = await WebRTC.invokeMethod('pipIsActive');
    return result == true;
  }
}
