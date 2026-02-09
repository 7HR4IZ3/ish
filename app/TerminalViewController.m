//
//  ViewController.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import "TerminalViewController.h"
#import "AppDelegate.h"
#import "TerminalView.h"
#import "BarButton.h"
#import "ArrowBarButton.h"
#import "UserPreferences.h"
#import "AboutViewController.h"
#import "CurrentRoot.h"
#import "NSObject+SaneKVO.h"
#import "LinuxInterop.h"
#import <objc/runtime.h>
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "fs/devices.h"

@interface SessionRecord : NSObject
@property (nonatomic) int pid;
@property (nonatomic) Terminal *terminal;
@property (nonatomic) NSString *name;
@end

@implementation SessionRecord
@end

@interface TerminalViewController () <UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>

@property UITapGestureRecognizer *tapRecognizer;
@property (weak, nonatomic) IBOutlet TerminalView *termView;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bottomConstraint;

@property (weak, nonatomic) IBOutlet UIButton *tabKey;
@property (weak, nonatomic) IBOutlet UIButton *controlKey;
@property (weak, nonatomic) IBOutlet UIButton *escapeKey;
@property (weak, nonatomic) BarButton *fnKey;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barButtons;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barControls;

@property (weak, nonatomic) IBOutlet UIInputView *barView;
@property (weak, nonatomic) IBOutlet UIStackView *bar;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTop;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barBottom;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barLeading;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTrailing;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barButtonWidth;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barHeight;
@property (weak, nonatomic) IBOutlet UIView *settingsBadge;
@property (nonatomic) UIScrollView *barScrollView;

@property (weak, nonatomic) IBOutlet UIButton *infoButton;
@property (weak, nonatomic) IBOutlet UIButton *pasteButton;
@property (weak, nonatomic) IBOutlet UIButton *hideKeyboardButton;

@property (nonatomic) NSMutableArray<SessionRecord *> *sessions;
@property (nonatomic) NSInteger selectedSessionIndex;

@property (nonatomic) UIView *sessionsSidebar;
@property (nonatomic) UITableView *sessionsTableView;
@property (nonatomic) UIButton *newSessionButton;
@property (nonatomic) NSUInteger nextSessionNumber;

@property BOOL ignoreKeyboardMotion;
@property (nonatomic) BOOL hasExternalKeyboard;

@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.sessions = [NSMutableArray new];
    self.selectedSessionIndex = NSNotFound;
    self.nextSessionNumber = 1;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        [self setupSessionsSidebar];

#if !ISH_LINUX
    int bootError = [AppDelegate bootError];
    if (bootError < 0) {
        NSString *message = [NSString stringWithFormat:@"could not boot"];
        NSString *subtitle = [NSString stringWithFormat:@"error code %d", bootError];
        if (bootError == _EINVAL)
            subtitle = [subtitle stringByAppendingString:@"\n(try reinstalling the app, see release notes for details)"];
        [self showMessage:message subtitle:subtitle];
        NSLog(@"boot failed with code %d", bootError);
    }
#endif

    self.terminal = self.terminal;
    [self.termView becomeFirstResponder];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(_updateBadge)
                   name:FsUpdatedNotification
                 object:nil];


    [self _updateStyleFromPreferences:NO];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [self.bar removeArrangedSubview:self.hideKeyboardButton];
        [self.hideKeyboardButton removeFromSuperview];
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        self.barHeight.constant = 36;
    } else {
        self.barHeight.constant = 43;
    }

    [self configureScrollableKeyboardExtender];
    [self addExtraKeyboardExtenderButtons];
    
    // SF Symbols is cool
    if (@available(iOS 13, *)) {
        [self.infoButton setImage:[UIImage systemImageNamed:@"gear"] forState:UIControlStateNormal];
        [self.pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
        [self.hideKeyboardButton setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] forState:UIControlStateNormal];
        
        [self.tabKey setTitle:nil forState:UIControlStateNormal];
        [self.tabKey setImage:[UIImage systemImageNamed:@"arrow.right.to.line.alt"] forState:UIControlStateNormal];
        [self.controlKey setTitle:nil forState:UIControlStateNormal];
        [self.controlKey setImage:[UIImage systemImageNamed:@"control"] forState:UIControlStateNormal];
        [self.escapeKey setTitle:nil forState:UIControlStateNormal];
        [self.escapeKey setImage:[UIImage systemImageNamed:@"escape"] forState:UIControlStateNormal];
    }
    
    [UserPreferences.shared observe:@[@"hideStatusBar"] options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsStatusBarAppearanceUpdate];
        });
    }];
    [UserPreferences.shared observe:@[@"colorScheme", @"theme", @"hideExtraKeysWithExternalKeyboard"]
                            options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyleFromPreferences:YES];
        });
    }];
    [self _updateBadge];
}

- (void)configureScrollableKeyboardExtender {
    if ([self.bar.superview isKindOfClass:UIScrollView.class])
        return;

    UIView *container = self.bar.superview;
    if (container == nil)
        return;

    CGFloat leading = self.barLeading.constant;
    CGFloat trailing = self.barTrailing.constant;
    CGFloat top = self.barTop.constant;
    CGFloat bottom = self.barBottom.constant;

    [NSLayoutConstraint deactivateConstraints:@[self.barLeading, self.barTrailing, self.barTop, self.barBottom]];

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;
    scrollView.directionalLockEnabled = YES;
    [container addSubview:scrollView];

    UILayoutGuide *safeArea = container.safeAreaLayoutGuide;
    self.barLeading = [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:leading];
    self.barTrailing = [safeArea.trailingAnchor constraintEqualToAnchor:scrollView.trailingAnchor constant:trailing];
    self.barTop = [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:top];
    self.barBottom = [safeArea.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:bottom];
    [NSLayoutConstraint activateConstraints:@[self.barLeading, self.barTrailing, self.barTop, self.barBottom]];

    [self.bar removeFromSuperview];
    [scrollView addSubview:self.bar];
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.bar.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [self.bar.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [self.bar.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [self.bar.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [self.bar.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    self.barScrollView = scrollView;
}

- (void)addExtraKeyboardExtenderButtons {
    NSArray<NSDictionary<NSString *, NSString *> *> *keys = @[
        @{@"title": @"Fn", @"action": @"fn", @"label": @"Function"},
        @{@"title": @"PgUp", @"input": @"\x1b[5~", @"label": @"Page Up"},
        @{@"title": @"PgDn", @"input": @"\x1b[6~", @"label": @"Page Down"},
        @{@"title": @"Home", @"input": @"\x1b[H", @"label": @"Home"},
        @{@"title": @"End", @"input": @"\x1b[F", @"label": @"End"},
        @{@"title": @"Ins", @"input": @"\x1b[2~", @"label": @"Insert"},
        @{@"title": @"Del", @"input": @"\x1b[3~", @"label": @"Delete"},
    ];

    NSInteger spacerIndex = [self.bar.arrangedSubviews indexOfObjectPassingTest:^BOOL(UIView *view, NSUInteger idx, BOOL *stop) {
        return ![view isKindOfClass:UIControl.class];
    }];
    if (spacerIndex == NSNotFound)
        spacerIndex = self.bar.arrangedSubviews.count;

    NSMutableArray *barButtons = self.barButtons.mutableCopy ?: [NSMutableArray new];
    NSMutableArray *barControls = self.barControls.mutableCopy ?: [NSMutableArray new];

    for (NSDictionary<NSString *, NSString *> *entry in keys) {
        BarButton *button = [BarButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.titleLabel.font = [UIFont systemFontOfSize:20];
        [button setTitle:entry[@"title"] forState:UIControlStateNormal];
        button.accessibilityLabel = entry[@"label"];
        if ([entry[@"action"] isEqualToString:@"fn"]) {
            [button addTarget:self action:@selector(pressFn:) forControlEvents:UIControlEventTouchUpInside];
            button.toggleable = YES;
            self.fnKey = button;
        } else {
            [button addTarget:self action:@selector(pressDynamicKey:) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(button, @selector(pressDynamicKey:), entry[@"input"], OBJC_ASSOCIATION_COPY_NONATOMIC);
        }

        [self.bar insertArrangedSubview:button atIndex:spacerIndex++];
        [button.widthAnchor constraintEqualToAnchor:self.infoButton.widthAnchor].active = YES;

        [barButtons addObject:button];
        [barControls addObject:button];
    }

    self.barButtons = barButtons;
    self.barControls = barControls;
}

- (IBAction)pressDynamicKey:(UIButton *)sender {
    NSString *key = objc_getAssociatedObject(sender, _cmd);
    if (key != nil)
        [self pressKey:key];
}

- (IBAction)pressFn:(BarButton *)sender {
    sender.selected = !sender.selected;
}

- (void)awakeFromNib {
    [super awakeFromNib];
#if !ISH_LINUX
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(processExited:)
                                               name:ProcessExitedNotification
                                             object:nil];
#else
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(kernelPanicked:)
                                               name:KernelPanicNotification
                                             object:nil];
#endif
}

- (void)viewDidAppear:(BOOL)animated {
    [AppDelegate maybePresentStartupMessageOnViewController:self];
    [super viewDidAppear:animated];
}

- (void)startNewSession {
    int err = [self startSession];
    if (err < 0) {
        [self showMessage:@"could not start session"
                 subtitle:[NSString stringWithFormat:@"error code %d", err]];
    }
}

- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        [self startNewSession];
        return;
    }
    [self reconnectSessionsFromTerminalUUIDStrings:@[uuid.UUIDString] sessionPIDs:@[]];
}

- (void)reconnectSessionsFromTerminalUUIDStrings:(NSArray<NSString *> *)uuidStrings {
    [self reconnectSessionsFromTerminalUUIDStrings:uuidStrings sessionPIDs:@[]];
}

- (void)reconnectSessionsFromTerminalUUIDStrings:(NSArray<NSString *> *)uuidStrings sessionPIDs:(NSArray<NSNumber *> *)sessionPIDs {
    BOOL restoredAny = NO;
    for (NSUInteger i = 0; i < uuidStrings.count; i++) {
        NSString *uuidString = uuidStrings[i];
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
        if (uuid == nil)
            continue;
        Terminal *terminal = [Terminal terminalWithUUID:uuid];
        if (terminal == nil)
            continue;

        int pid = -1;
        if (i < sessionPIDs.count && [sessionPIDs[i] isKindOfClass:NSNumber.class])
            pid = sessionPIDs[i].intValue;
        [self addSessionWithTerminal:terminal pid:pid];
        restoredAny = YES;
    }

    if (!restoredAny)
        [self startNewSession];
}

- (NSUUID *)sessionTerminalUUID {
    SessionRecord *session = [self selectedSession];
    return session.terminal.uuid;
}

- (NSArray<NSString *> *)sessionTerminalUUIDStrings {
    NSMutableArray<NSString *> *uuids = [NSMutableArray new];
    for (SessionRecord *session in self.sessions) {
        if (session.terminal.uuid != nil)
            [uuids addObject:session.terminal.uuid.UUIDString];
    }
    return uuids;
}

- (NSArray<NSNumber *> *)sessionPIDs {
    NSMutableArray<NSNumber *> *pids = [NSMutableArray new];
    for (SessionRecord *session in self.sessions) {
        if (session.terminal.uuid != nil)
            [pids addObject:@(session.pid)];
    }
    return pids;
}

- (int)startSession {
    NSArray<NSString *> *command = UserPreferences.shared.launchCommand;

#if !ISH_LINUX
    int err = become_new_init_child();
    if (err < 0)
        return err;
    struct tty *tty;

    Terminal *terminal = [Terminal createPseudoTerminal:&tty];
    if (terminal == nil) {
        NSAssert(IS_ERR(tty), @"tty should be error");
        return (int) PTR_ERR(tty);
    }

    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) {
        tty_release(tty);
        [terminal destroy];
        return err;
    }
    tty_release(tty);

    char argv[4096];
    [Terminal convertCommand:command toArgs:argv limitSize:sizeof(argv)];
    const char *envp = "TERM=xterm-256color\0";
    err = do_execve(command[0].UTF8String, command.count, argv, envp);
    if (err < 0) {
        [terminal destroy];
        return err;
    }
    int sessionPid = current->pid;
    [self addSessionWithTerminal:terminal pid:sessionPid];
    task_start(current);
#else
    const char *argv_arr[command.count + 1];
    for (NSUInteger i = 0; i < command.count; i++)
        argv_arr[i] = command[i].UTF8String;
    argv_arr[command.count] = NULL;
    const char *envp_arr[] = {
        "TERM=xterm-256color",
        NULL,
    };
    const char *const *argv = argv_arr;
    const char *const *envp = envp_arr;
    __block Terminal *terminal = nil;
    __block int sessionPid = 0;
    __block int err = 1;
    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(argv[0], argv, envp, ^(int retval, int pid, nsobj_t term) {
            err = retval;
            if (term)
                terminal = CFBridgingRelease(term);
            sessionPid = pid;
            done();
        });
    });
    NSAssert(err <= 0, @"session start did not finish??");
    if (err < 0)
        return err;

    [self addSessionWithTerminal:terminal pid:sessionPid];
#endif
    return 0;
}

#if !ISH_LINUX
- (void)processExited:(NSNotification *)notif {
    int pid = [notif.userInfo[@"pid"] intValue];
    NSInteger index = [self indexOfSessionWithPid:pid];
    if (index == NSNotFound) {
        id terminalUUIDValue = notif.userInfo[@"terminalUUID"];
        if (![terminalUUIDValue isKindOfClass:NSString.class] || ((NSString *) terminalUUIDValue).length == 0)
            return;

        NSString *terminalUUID = (NSString *) terminalUUIDValue;
        NSInteger unknownPidSessionIndex = NSNotFound;
        for (NSInteger i = 0; i < self.sessions.count; i++) {
            SessionRecord *session = self.sessions[i];
            if (session.pid >= 0)
                continue;
            if (![session.terminal.uuid.UUIDString isEqualToString:terminalUUID])
                continue;
            if (unknownPidSessionIndex != NSNotFound)
                return;
            unknownPidSessionIndex = i;
        }
        if (unknownPidSessionIndex == NSNotFound)
            return;
        index = unknownPidSessionIndex;
    }

    SessionRecord *session = self.sessions[index];
    [session.terminal destroy];
    [self.sessions removeObjectAtIndex:index];
    [self.sessionsTableView reloadData];

    if (self.sessions.count == 0) {
        self.selectedSessionIndex = NSNotFound;
        current = NULL; // it's been freed
        [self startNewSession];
    } else {
        NSInteger newIndex = MIN(index, (NSInteger) self.sessions.count - 1);
        [self selectSessionAtIndex:newIndex];
    }
}
#endif

#if ISH_LINUX
- (void)kernelPanicked:(NSNotification *)notif {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"panik" message:notif.userInfo[@"message"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"k" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)showMessage:(NSString *)message subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:message message:subtitle preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"k"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == [UserPreferences shared]) {
        [self _updateStyleFromPreferences:YES];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_updateStyleFromPreferences:(BOOL)animated {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    NSTimeInterval duration = animated ? 0.1 : 0;
    [UIView animateWithDuration:duration animations:^{
        self.view.backgroundColor = [[UIColor alloc] ish_initWithHexString:UserPreferences.shared.palette.backgroundColor];
        UIKeyboardAppearance keyAppearance = UserPreferences.shared.keyboardAppearance;
        self.termView.keyboardAppearance = keyAppearance;
        for (BarButton *button in self.barButtons) {
            button.keyAppearance = keyAppearance;
        }
        UIColor *tintColor = keyAppearance == UIKeyboardAppearanceLight ? UIColor.blackColor : UIColor.whiteColor;
        for (UIControl *control in self.barControls) {
            control.tintColor = tintColor;
        }
    }];
    UIView *oldBarView = self.termView.inputAccessoryView;
    if (UserPreferences.shared.hideExtraKeysWithExternalKeyboard && self.hasExternalKeyboard) {
        self.termView.inputAccessoryView = nil;
    } else {
        self.termView.inputAccessoryView = self.barView;
    }
    if (self.termView.inputAccessoryView != oldBarView && self.termView.isFirstResponder) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ignoreKeyboardMotion = YES; // avoid infinite recursion
            [self.termView reloadInputViews];
            self.ignoreKeyboardMotion = NO;
        });
    }
}
- (void)_updateStyleAnimated {
    [self _updateStyleFromPreferences:YES];
}

- (void)_updateBadge {
    self.settingsBadge.hidden = !FsNeedsRepositoryUpdate();
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UserPreferences.shared.statusBarStyle;
}

- (BOOL)prefersStatusBarHidden {
    return UserPreferences.shared.hideStatusBar;
}

- (void)keyboardDidSomething:(NSNotification *)notification {
    if (self.ignoreKeyboardMotion)
        return;

    CGRect screenKeyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIScreen *screen = UIScreen.mainScreen;
    // notification.object is nil before iOS 16.1 and the correct UIScreen after iOS 16.1
    if (notification.object != nil)
        screen = notification.object;
    CGRect keyboardFrame = [self.view convertRect:screenKeyboardFrame fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectEqualToRect(keyboardFrame, CGRectZero))
        return;
    CGRect intersection = CGRectIntersection(keyboardFrame, self.view.bounds);
    keyboardFrame = intersection;
    NSLog(@"%@ %@", notification.name, @(keyboardFrame));
    self.hasExternalKeyboard = keyboardFrame.size.height < 100;
    CGFloat pad = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardFrame);
    // The keyboard appears to be undocked. This means it can either be split or
    // truly floating. In the former case we want to keep the pad, but in the
    // latter we should fall back to the input accessory view instead of the
    // keyboard.
    if (pad != keyboardFrame.size.height && keyboardFrame.size.width != UIScreen.mainScreen.bounds.size.width) {
        pad = MAX(self.view.safeAreaInsets.bottom, self.termView.inputAccessoryView.frame.size.height);
    }
    // NSLog(@"pad %f", pad);
    self.bottomConstraint.constant = pad;

    BOOL initialLayout = self.termView.needsUpdateConstraints;
    [self.view setNeedsUpdateConstraints];
    if (!initialLayout) {
        // if initial layout hasn't happened yet, the terminal view is going to be at a really weird place, so animating it is going to look really bad
        NSNumber *interval = notification.userInfo[UIKeyboardAnimationDurationUserInfoKey];
        NSNumber *curve = notification.userInfo[UIKeyboardAnimationCurveUserInfoKey];
        [UIView animateWithDuration:interval.doubleValue
                              delay:0
                            options:curve.integerValue << 16
                         animations:^{
                             [self.view layoutIfNeeded];
                         }
                         completion:nil];
    }
}

- (void)setHasExternalKeyboard:(BOOL)hasExternalKeyboard {
    _hasExternalKeyboard = hasExternalKeyboard;
    [self _updateStyleFromPreferences:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"embed"]) {
        // You might want to check if this is your embed segue here
        // in case there are other segues triggered from this view controller.
        segue.destinationViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    // Hack to resolve a layering mismatch between the UI and preferences.
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // Ensure that the relevant things listening for this will update.
            UserPreferences.shared.colorScheme = UserPreferences.shared.colorScheme;
        }
    }
}

#pragma mark Bar

- (IBAction)showAbout:(id)sender {
    UINavigationController *navigationController = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
    if ([sender isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *recognizer = sender;
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            AboutViewController *aboutViewController = (AboutViewController *) navigationController.topViewController;
            aboutViewController.includeDebugPanel = YES;
        } else {
            return;
        }
    }
    [self presentViewController:navigationController animated:YES completion:nil];
    [self.termView resignFirstResponder];
}

- (void)resizeBar {
    CGSize bar = self.barView.bounds.size;
    // set sizing parameters on bar
    // numbers stolen from iVim and modified somewhat
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        // phone
        [self setBarHorizontalPadding:6 verticalPadding:6 buttonWidth:32];
    } else if (bar.width >= 450) {
        // wide ipad
        [self setBarHorizontalPadding:15 verticalPadding:8 buttonWidth:43];
    } else {
        // narrow ipad (slide over)
        [self setBarHorizontalPadding:10 verticalPadding:8 buttonWidth:36];
    }
    [UIView performWithoutAnimation:^{
        [self.barView layoutIfNeeded];
    }];
}

- (void)setBarHorizontalPadding:(CGFloat)horizontal verticalPadding:(CGFloat)vertical buttonWidth:(CGFloat)buttonWidth {
    self.barLeading.constant = self.barTrailing.constant = horizontal;
    self.barTop.constant = self.barBottom.constant = vertical;
    self.barButtonWidth.constant = buttonWidth;
}

- (IBAction)pressEscape:(id)sender {
    [self pressKey:@"\x1b"];
}
- (IBAction)pressTab:(id)sender {
    [self pressKey:@"\t"];
}
- (IBAction)pressMinus:(id)sender {
    [self pressKey:@"-"];
}
- (IBAction)pressSlash:(id)sender {
    [self pressKey:@"/"];
}
- (IBAction)pressPipe:(id)sender {
    [self pressKey:@"|"];
}
- (void)pressKey:(NSString *)key {
    [self.termView insertText:key];
}

- (IBAction)pressControl:(id)sender {
    self.controlKey.selected = !self.controlKey.selected;
}
    
- (IBAction)pressArrow:(ArrowBarButton *)sender {
    if (self.fnKey.selected) {
        switch (sender.direction) {
            case ArrowUp: [self pressKey:@"\x1b[5~"]; break;
            case ArrowDown: [self pressKey:@"\x1b[6~"]; break;
            case ArrowLeft: [self pressKey:@"\x1b[H"]; break;
            case ArrowRight: [self pressKey:@"\x1b[F"]; break;
            case ArrowNone: break;
        }
        self.fnKey.selected = NO;
        return;
    }
    switch (sender.direction) {
        case ArrowUp: [self pressKey:[self.terminal arrow:'A']]; break;
        case ArrowDown: [self pressKey:[self.terminal arrow:'B']]; break;
        case ArrowLeft: [self pressKey:[self.terminal arrow:'D']]; break;
        case ArrowRight: [self pressKey:[self.terminal arrow:'C']]; break;
        case ArrowNone: break;
    }
}

- (void)switchTerminal:(UIKeyCommand *)sender {
    unsigned i = (unsigned) sender.input.integerValue;
    if (i == 7) {
        SessionRecord *session = [self selectedSession];
        if (session != nil)
            self.terminal = session.terminal;
    } else {
        self.terminal = [Terminal terminalWithType:TTY_CONSOLE_MAJOR number:i];
    }
}

- (void)increaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize + 1;
}
- (void)decreaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize - 1;
}
- (void)resetFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = 0;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    static NSMutableArray<UIKeyCommand *> *commands = nil;
    if (commands == nil) {
        commands = [NSMutableArray new];
        for (unsigned i = 1; i <= 7; i++) {
            [commands addObject:
             [UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%d", i]
                                 modifierFlags:UIKeyModifierCommand|UIKeyModifierAlternate|UIKeyModifierShift
                                        action:@selector(switchTerminal:)]];
        }
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"+"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)
                      discoverabilityTitle:@"Increase Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"="
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"-"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(decreaseFontSize:)
                      discoverabilityTitle:@"Decrease Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"0"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(resetFontSize:)
                      discoverabilityTitle:@"Reset Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@","
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(showAbout:)
                      discoverabilityTitle:@"Settings"]];
    }
    return commands;
}

- (void)setTerminal:(Terminal *)terminal {
    _terminal = terminal;
    self.termView.terminal = self.terminal;
}

- (SessionRecord *)selectedSession {
    if (self.selectedSessionIndex == NSNotFound || self.selectedSessionIndex >= self.sessions.count)
        return nil;
    return self.sessions[self.selectedSessionIndex];
}

- (NSInteger)indexOfSessionWithPid:(int)pid {
    for (NSInteger i = 0; i < self.sessions.count; i++) {
        if (self.sessions[i].pid == pid)
            return i;
    }
    return NSNotFound;
}

- (void)addSessionWithTerminal:(Terminal *)terminal pid:(int)pid {
    SessionRecord *session = [SessionRecord new];
    session.terminal = terminal;
    session.pid = pid;
    session.name = [NSString stringWithFormat:@"Session %lu", (unsigned long) self.nextSessionNumber++];
    [self.sessions addObject:session];
    [self.sessionsTableView reloadData];
    [self selectSessionAtIndex:self.sessions.count - 1];
}

- (void)selectSessionAtIndex:(NSInteger)index {
    if (index == NSNotFound || index >= self.sessions.count)
        return;
    self.selectedSessionIndex = index;
    self.terminal = self.sessions[index].terminal;
    if (self.sessionsTableView != nil) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
        [self.sessionsTableView reloadData];
        [self.sessionsTableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
    }
}

- (void)setupSessionsSidebar {
    UIView *sidebar = [[UIView alloc] initWithFrame:CGRectZero];
    sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    sidebar.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = UIColor.clearColor;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"New Session" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button addTarget:self action:@selector(startNewSession) forControlEvents:UIControlEventTouchUpInside];

    [sidebar addSubview:table];
    [sidebar addSubview:button];
    [self.view addSubview:sidebar];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:220],

        [button.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:12],
        [button.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-12],
        [button.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-12],
        [button.heightAnchor constraintEqualToConstant:44],

        [table.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [table.topAnchor constraintEqualToAnchor:sidebar.topAnchor],
        [table.bottomAnchor constraintEqualToAnchor:button.topAnchor constant:-8],
    ]];

    self.sessionsSidebar = sidebar;
    self.sessionsTableView = table;
    self.newSessionButton = button;

    NSLayoutConstraint *terminalLeading = nil;
    for (NSLayoutConstraint *constraint in self.view.constraints) {
        BOOL matches = (constraint.firstItem == self.termView && constraint.firstAttribute == NSLayoutAttributeLeading)
            || (constraint.secondItem == self.termView && constraint.secondAttribute == NSLayoutAttributeLeading);
        if (matches) {
            terminalLeading = constraint;
            break;
        }
    }
    if (terminalLeading != nil)
        terminalLeading.active = NO;
    [self.termView.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor].active = YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sessions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"SessionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];

    SessionRecord *session = self.sessions[indexPath.row];
    cell.textLabel.text = session.name;
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = UIColor.whiteColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self selectSessionAtIndex:indexPath.row];
}

@end

@interface BarView : UIInputView
@property (weak) IBOutlet TerminalViewController *terminalViewController;
@property (nonatomic) IBInspectable BOOL allowsSelfSizing;
@end
@implementation BarView
@dynamic allowsSelfSizing;

- (void)layoutSubviews {
    [self.terminalViewController resizeBar];
}

@end
