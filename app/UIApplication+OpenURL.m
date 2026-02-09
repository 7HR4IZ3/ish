//
//  UIApplication+OpenURL.m
//  iSH
//
//  Created by Theodore Dubois on 9/23/18.
//

#import "UIApplication+OpenURL.h"

@implementation UIApplication (OpenURL)

+ (void)openURL:(NSString *)url {
    NSURL *parsedURL = [NSURL URLWithString:url];
    if (parsedURL == nil)
        return;
    [[self sharedApplication] openURL:parsedURL options:@{} completionHandler:^(BOOL success) {
        if (!success)
            NSLog(@"failed to open URL: %@", url);
    }];
}

@end
