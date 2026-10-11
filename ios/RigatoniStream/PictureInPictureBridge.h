#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface PictureInPictureBridge : NSObject <VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling>
- (instancetype)initWithView:(UIView *)view player:(VLCMediaPlayer *)player;
@property (nonatomic, copy, nullable) void (^availabilityChanged)(BOOL);
@property (nonatomic, copy, nullable) void (^activeChanged)(BOOL);
- (void)startPictureInPicture;
- (void)invalidatePlaybackState;
- (void)detach;
@end
NS_ASSUME_NONNULL_END
