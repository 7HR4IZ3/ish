//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"

TerminalViewController *currentTerminalViewController = NULL;

static TerminalViewController *terminalViewControllerFromRoot(UIViewController *rootViewController) {
    if ([rootViewController isKindOfClass:TerminalViewController.class])
        return (TerminalViewController *) rootViewController;
    if ([rootViewController isKindOfClass:UINavigationController.class]) {
        UIViewController *visibleViewController = ((UINavigationController *) rootViewController).visibleViewController;
        if ([visibleViewController isKindOfClass:TerminalViewController.class])
            return (TerminalViewController *) visibleViewController;
    }
    return nil;
}

@interface SceneDelegate ()

@property NSString *terminalUUID;

@end

static NSString *const TerminalUUID = @"TerminalUUID";
static NSString *const TerminalUUIDs = @"TerminalUUIDs";
static NSString *const TerminalSessionPIDs = @"TerminalSessionPIDs";

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
        return;
    }

    TerminalViewController *vc = terminalViewControllerFromRoot(self.window.rootViewController);
    if (vc == nil)
        return;
    vc.sceneSession = session;
    if (session.stateRestorationActivity == nil) {
        [vc startNewSession];
    } else {
        NSDictionary *userInfo = session.stateRestorationActivity.userInfo;
        NSArray<NSString *> *terminalUUIDs = userInfo[TerminalUUIDs];
        if ([terminalUUIDs isKindOfClass:NSArray.class] && terminalUUIDs.count > 0) {
            NSArray<NSNumber *> *sessionPIDs = userInfo[TerminalSessionPIDs];
            if (![sessionPIDs isKindOfClass:NSArray.class])
                sessionPIDs = @[];
            [vc reconnectSessionsFromTerminalUUIDStrings:terminalUUIDs sessionPIDs:sessionPIDs];
        } else {
            self.terminalUUID = userInfo[TerminalUUID];
            [vc reconnectSessionFromTerminalUUID:
             [[NSUUID alloc] initWithUUIDString:self.terminalUUID]];
        }
    }
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:@"app.ish.scene"];
    TerminalViewController *vc = terminalViewControllerFromRoot(self.window.rootViewController);
    if ([vc isKindOfClass:TerminalViewController.class]) {
        NSArray<NSString *> *terminalUUIDs = vc.sessionTerminalUUIDStrings;
        NSArray<NSNumber *> *sessionPIDs = vc.sessionPIDs;
        NSUUID *selectedUUID = vc.sessionTerminalUUID;
        if (terminalUUIDs.count > 0) {
            if (sessionPIDs.count != terminalUUIDs.count)
                sessionPIDs = @[];
            NSMutableArray<NSString *> *orderedUUIDs = terminalUUIDs.mutableCopy;
            NSMutableArray<NSNumber *> *orderedPIDs = sessionPIDs.mutableCopy;
            if (selectedUUID != nil) {
                NSUInteger selectedIndex = [orderedUUIDs indexOfObject:selectedUUID.UUIDString];
                if (selectedIndex != NSNotFound && selectedIndex + 1 != orderedUUIDs.count) {
                    NSString *selectedUUIDString = orderedUUIDs[selectedIndex];
                    NSNumber *selectedPid = orderedPIDs.count == orderedUUIDs.count ? orderedPIDs[selectedIndex] : nil;
                    [orderedUUIDs removeObjectAtIndex:selectedIndex];
                    if (selectedIndex < orderedPIDs.count)
                        [orderedPIDs removeObjectAtIndex:selectedIndex];
                    [orderedUUIDs addObject:selectedUUIDString];
                    if (selectedPid != nil)
                        [orderedPIDs addObject:selectedPid];
                }
            }
            NSMutableDictionary *userInfo = [@{TerminalUUIDs: orderedUUIDs,
                                               TerminalUUID: selectedUUID.UUIDString ?: orderedUUIDs.lastObject} mutableCopy];
            if (orderedPIDs.count == orderedUUIDs.count)
                userInfo[TerminalSessionPIDs] = orderedPIDs;
            [activity addUserInfoEntriesFromDictionary:userInfo];
        }
    }
    return activity;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = terminalViewControllerFromRoot(self.window.rootViewController);
    currentTerminalViewController = terminalViewController;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = terminalViewControllerFromRoot(self.window.rootViewController);

    if (currentTerminalViewController == terminalViewController) {
        currentTerminalViewController = NULL;
    }
}

@end
