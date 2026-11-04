#import "GXSceneDelegate.h"
#import "GXCameraViewController.h"

@implementation GXSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    (void)session; (void)connectionOptions;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [GXCameraViewController new];
    [self.window makeKeyAndVisible];
}
@end
