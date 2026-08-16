//
//  ViewController.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

@interface TerminalViewController : UIViewController

@property (nonatomic) Terminal *terminal;

- (void)startNewSession;
- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid;
- (void)reconnectSessionsFromTerminalUUIDStrings:(NSArray<NSString *> *)uuidStrings;
- (void)reconnectSessionsFromTerminalUUIDStrings:(NSArray<NSString *> *)uuidStrings sessionPIDs:(NSArray<NSNumber *> *)sessionPIDs;
@property (readonly) NSUUID *sessionTerminalUUID;
@property (readonly) NSArray<NSString *> *sessionTerminalUUIDStrings;
@property (readonly) NSArray<NSNumber *> *sessionPIDs;
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

@end

extern struct tty_driver ios_tty_driver;
