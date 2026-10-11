#import "PictureInPictureBridge.h"
#include <limits.h>
// Uses VideoLAN's native sample-buffer output, without a second stream.
@implementation PictureInPictureBridge {
    __weak UIView *_view;
    __weak VLCMediaPlayer *_player;
    id<VLCPictureInPictureWindowControlling> _controller;
}
- (instancetype)initWithView:(UIView *)view player:(VLCMediaPlayer *)player {
    if ((self = [super init])) { _view = view; _player = player; }
    return self;
}
- (void)addSubview:(UIView *)view { [_view addSubview:view]; }
- (CGRect)bounds { return _view.bounds; }
- (id<VLCPictureInPictureMediaControlling>)mediaController { return self; }
- (void (^)(id<VLCPictureInPictureWindowControlling>))pictureInPictureReady {
    __weak typeof(self) weakSelf = self;
    return ^(id<VLCPictureInPictureWindowControlling> controller) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PictureInPictureBridge *bridge = weakSelf;
            if (!bridge || !bridge->_player) return;
            bridge->_controller = controller;
            controller.stateChangeEventHandler = ^(BOOL active) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    PictureInPictureBridge *bridge = weakSelf;
                    if (bridge.activeChanged) bridge.activeChanged(active);
                });
            };
            if (bridge.availabilityChanged) bridge.availabilityChanged(YES);
        });
    };
}
- (void)startPictureInPicture { [_controller startPictureInPicture]; }
- (void)invalidatePlaybackState { [_controller invalidatePlaybackState]; }
- (void)detach {
    [_controller stopPictureInPicture];
    _controller.stateChangeEventHandler = nil; _controller = nil;
    self.availabilityChanged = nil; self.activeChanged = nil;
    _view = nil; _player = nil;
}
- (void)play { [_player play]; }
- (void)pause { [_player pause]; }
- (void)seekBy:(int64_t)offset completion:(dispatch_block_t)completion {
    int interval = (int)MAX(INT_MIN, MIN(INT_MAX, offset));
    if (![_player jumpWithOffset:interval completion:completion]) completion();
}
- (int64_t)mediaLength { return _player.media.length.value.longLongValue; }
- (int64_t)mediaTime { return _player.time.value.longLongValue; }
- (BOOL)isMediaSeekable { return _player.isSeekable; }
- (BOOL)isMediaPlaying { return _player.isPlaying; }
@end
