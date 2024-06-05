// This file is part of Background Music.
//
// Background Music is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 2 of the
// License, or (at your option) any later version.
//
// Background Music is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Background Music. If not, see <http://www.gnu.org/licenses/>.

//
//  BGMAppDelegate.mm
//  BGMApp
//
//  Copyright © 2016-2022 Kyle Neideck
//  Copyright © 2021 Marcus Wu
//

// Self Include
#import "BGMAppDelegate.h"

// Local Includes
#import "BGM_Utils.h"
#import "BGMAppVolumes.h"
#import "BGMAppVolumesController.h"
#import "BGMAutoPauseMusic.h"
#import "BGMAutoPauseMenuItem.h"
#import "BGMDebugLoggingMenuItem.h"
#import "BGMMusicPlayers.h"
#import "BGMOutputDeviceMenuSection.h"
#import "BGMOutputVolumeMenuItem.h"
#import "BGMPreferencesMenu.h"
#import "BGMPreferredOutputDevices.h"
#import "BGMStatusBarItem.h"
#import "BGMSystemSoundsVolume.h"
#import "BGMTermination.h"
#import "BGMUserDefaults.h"
#import "BGMXPCListener.h"
#import "SystemPreferences.h"

// System Includes
#import <AVFoundation/AVCaptureDevice.h>


#pragma clang assume_nonnull begin

static NSString* const kOptNoPersistentData  = @"--no-persistent-data";
static NSString* const kOptShowDockIcon      = @"--show-dock-icon";

@implementation BGMAppDelegate {
    // The button in the system status bar that shows the main menu.
    BGMStatusBarItem* statusBarItem;
    
    // Only show the 'BGMXPCHelper is missing' error dialog once.
    BOOL haveShownXPCHelperErrorMessage;

    // Persistently stores user settings and data.
    BGMUserDefaults* userDefaults;

    BGMAutoPauseMusic* autoPauseMusic;
    BGMAutoPauseMenuItem* autoPauseMenuItem;
    BGMMusicPlayers* musicPlayers;
    BGMSystemSoundsVolume* systemSoundsVolume;
    BGMOutputDeviceMenuSection* outputDeviceMenuSection;
    BGMPreferencesMenu* prefsMenu;
    BGMDebugLoggingMenuItem* debugLoggingMenuItem;
    BGMXPCListener* xpcListener;
    BGMPreferredOutputDevices* preferredOutputDevices;
}

@synthesize audioDevices = audioDevices;
@synthesize appVolumes = appVolumes;

- (void) awakeFromNib {
    [super awakeFromNib];
    
    // Show BGMApp in the dock, if the command-line option for that was passed. This is used by the
    // UI tests.
    if ([NSProcessInfo.processInfo.arguments indexOfObject:kOptShowDockIcon] != NSNotFound) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
    
    haveShownXPCHelperErrorMessage = NO;

    // Set up audioDevices, which coordinates BGMDevice and the output device. It manages
    // playthrough, volume/mute controls, etc.
    if (![self initAudioDeviceManager]) {
        return;
    }

    // Stored user settings
    userDefaults = [self createUserDefaults];

    // Add the status bar item. (The thing you click to show BGMApp's main menu.)
    statusBarItem = [[BGMStatusBarItem alloc] initWithMenu:self.bgmMenu
                                              audioDevices:audioDevices
                                              userDefaults:userDefaults];
}

- (void) applicationDidFinishLaunching:(NSNotification*)aNotification {
    #pragma unused (aNotification)
    
    // Log the version/build number.
    //
    // TODO: NSLog should only be used for logging errors.
    // TODO: Automatically add the commit ID to the end of the build number for unreleased builds. (In the
    //       Info.plist or something -- not here.)
    NSLog(@"BGMApp version: %@, BGMApp build number: %@",
          NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
          NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]);

    // Handles changing (or not changing) the output device when devices are added or removed. Must
    // be initialised before calling setBGMDeviceAsDefault.
    preferredOutputDevices =
        [[BGMPreferredOutputDevices alloc] initWithDevices:audioDevices userDefaults:userDefaults];

    // Skip this if we're compiling on a version of macOS before 10.14 as won't compile and it
    // isn't needed.
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101400  // MAC_OS_X_VERSION_10_14
    if (@available(macOS 10.14, *)) {
        // On macOS 10.14+ we need to get the user's permission to use input devices before we can
        // use BGMDevice for playthrough (see BGMPlayThrough), so we wait until they've given it
        // before making BGMDevice the default device. This way, if the user is playing audio when
        // they open Background Music, we won't interrupt it while we're waiting for them to click
        // OK.
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    DebugMsg("BGMAppDelegate::applicationDidFinishLaunching: Permission granted");
                    [self continueLaunchAfterInputDevicePermissionGranted];
                } else {
                    NSLog(@"BGMAppDelegate::applicationDidFinishLaunching: Permission denied");
                    // If they don't accept, Background Music won't work at all and the only way to
                    // fix it is in System Preferences, so show an error dialog with instructions.
                    //
                    // TODO: It would be nice if this dialog had a shortcut to open the System
                    //       Preferences panel. See showSetDeviceAsDefaultError.
                    [self showErrorMessage:@"Background Music needs permission to use microphones."
                           informativeText:@"It uses a virtual microphone to access your system's "
                                            "audio.\n\nYou can grant the permission by going to "
                                            "System Preferences > Security and Privacy > "
                                            "Microphone and checking the box for Background Music."
                 exitAfterMessageDismissed:YES];
                }
            });
        }];
    }
    else
#endif
    {
        // We can change the device immediately on older versions of macOS because they don't
        // require user permission for input devices.
        [self continueLaunchAfterInputDevicePermissionGranted];
    }
}

- (void) continueLaunchAfterInputDevicePermissionGranted {
    // Choose an output device for BGMApp to use to play audio.
    if (![self setInitialOutputDevice]) {
        return;
    }

    // Make BGMDevice the default device.
    [self setBGMDeviceAsDefault];

    // Handle some of the unusual reasons BGMApp might have to exit, mostly crashes.
    BGMTermination::SetUpTerminationCleanUp(audioDevices);

    // Set up the rest of the UI and other external interfaces.
    musicPlayers = [[BGMMusicPlayers alloc] initWithAudioDevices:audioDevices
                                                    userDefaults:userDefaults];

    autoPauseMusic = [[BGMAutoPauseMusic alloc] initWithAudioDevices:audioDevices
                                                        musicPlayers:musicPlayers];

    [self setUpMainMenu];

    xpcListener = [[BGMXPCListener alloc] initWithAudioDevices:audioDevices
                                  helperConnectionErrorHandler:^(NSError* error) {
        NSLog(@"BGMAppDelegate::continueLaunchAfterInputDevicePermissionGranted: "
              "(helperConnectionErrorHandler) BGMXPCHelper connection error: %@",
              error);
        [self showXPCHelperErrorMessage:error];
    }];
}

// Returns NO if (and only if) BGMApp is about to terminate because of a fatal error.
- (BOOL) initAudioDeviceManager {
    audioDevices = [BGMAudioDeviceManager new];

    if (!audioDevices) {
        [self showBGMDeviceNotFoundErrorMessageAndExit];
        return NO;
    }

    return YES;
}

// Returns NO if (and only if) BGMApp is about to terminate because of a fatal error.
- (BOOL) setInitialOutputDevice {
    AudioObjectID preferredDevice = [preferredOutputDevices findPreferredDevice];

    if (preferredDevice != kAudioObjectUnknown) {
        NSError* __nullable error = [audioDevices setOutputDeviceWithID:preferredDevice
                                                        revertOnFailure:NO];
        if (error) {
            // Show the error message.
            [self showFailedToSetOutputDeviceErrorMessage:BGMNN(error)
                                          preferredDevice:preferredDevice];
        }
    } else {
        // We couldn't find a device to use, so show an error message and quit.
        [self showOutputDeviceNotFoundErrorMessageAndExit];
        return NO;
    }

    return YES;
}

// Sets the "Background Music" virtual audio device (BGMDevice) as the user's default audio device.
- (void) setBGMDeviceAsDefault {
    NSError* error = [audioDevices setBGMDeviceAsOSDefault];

    if (error) {
        [self showSetDeviceAsDefaultError:error
                                  message:@"Could not set the Background Music device as your"
                                           "default audio device."
                          informativeText:@"You might be able to change it yourself."];
    }
}

- (void) menuWillOpen:(NSMenu*)menu {
    if (@available(macOS 10.16, *)) {
        // Set menu offset and check for any active menu items
        float menuOffset = 12.0;
        for (NSMenuItem* menuItem in self.bgmMenu.itemArray) {
            if (menuItem.state == NSControlStateValueOn && menuItem.indentationLevel == 0) {
                menuOffset += 10;
                break;
            }
        }
        
        // Align volume output device and slider
        for (NSView* subview in self.outputVolumeView.subviews) {
            CGRect newSubview = subview.frame;
            newSubview.origin.x = menuOffset;
            subview.frame = newSubview;
        }

        // Align system sounds and app volumes
        double appIconTitleOffset = 0;
        for (NSMenuItem* menuItem in self.bgmMenu.itemArray) {
            if (menuItem.view.subviews.count == 7 || menuItem.view.subviews.count == 3) {
                NSTextField* appTitle;
                NSImageView* appIcon;
                
                for (NSView* subview in menuItem.view.subviews) {
                    if (menuItem.view.subviews.count == 3) {
                        // System sounds
                        if ([subview isKindOfClass:[NSTextField class]]) {
                            appTitle = (NSTextField*)subview;
                        }
                        if ([subview isKindOfClass:[NSImageView class]]) {
                            appIcon = (NSImageView*)subview;
                        }
                    } else if (menuItem.view.subviews.count == 7) {
                        // App volumes
                        if ([subview isKindOfClass:[BGMAVM_AppNameLabel class]]) {
                            appTitle = (NSTextField*)subview;
                        }
                        if ([subview isKindOfClass:[BGMAVM_AppIcon class]]) {
                            appIcon = (NSImageView*)subview;
                        }
                    }
                }
 
                if (appIconTitleOffset == 0) {
                    appIconTitleOffset = appTitle.frame.origin.x - appIcon.frame.origin.x;
                }
                
                CGRect newAppIcon = appIcon.frame;
                newAppIcon.origin.x = menuOffset;
                appIcon.frame = newAppIcon;
                CGRect newAppTitle = appTitle.frame;
                newAppTitle.origin.x = menuOffset + appIconTitleOffset;
                appTitle.frame = newAppTitle;
            }
        }
    }
}

- (void) setUpMainMenu {
    autoPauseMenuItem =
        [[BGMAutoPauseMenuItem alloc] initWithMenuItem:self.autoPauseMenuItemUnwrapped
                                        autoPauseMusic:autoPauseMusic
                                          musicPlayers:musicPlayers
                                          userDefaults:userDefaults];

    [self initVolumesMenuSection];

    // Output device selection.
    outputDeviceMenuSection =
            [[BGMOutputDeviceMenuSection alloc] initWithBGMMenu:self.bgmMenu
                                                   audioDevices:audioDevices
                                               preferredDevices:preferredOutputDevices];
    [audioDevices setOutputDeviceMenuSection:outputDeviceMenuSection];

    // Preferences submenu.
    prefsMenu = [[BGMPreferencesMenu alloc] initWithBGMMenu:self.bgmMenu
                                               audioDevices:audioDevices
                                               musicPlayers:musicPlayers
                                              statusBarItem:statusBarItem
                                                 aboutPanel:self.aboutPanel
                                      aboutPanelLicenseView:self.aboutPanelLicenseView];

    // Enable/disable debug logging. Hidden unless you option-click the status bar icon.
    debugLoggingMenuItem =
        [[BGMDebugLoggingMenuItem alloc] initWithMenuItem:self.debugLoggingMenuItemUnwrapped];
    [statusBarItem setDebugLoggingMenuItem:debugLoggingMenuItem];

    // Handle events about the main menu. (See the NSMenuDelegate methods below.)
    self.bgmMenu.delegate = self;
}

- (BGMUserDefaults*) createUserDefaults {
    BOOL persistentDefaults =
        [NSProcessInfo.processInfo.arguments indexOfObject:kOptNoPersistentData] == NSNotFound;
    NSUserDefaults* wrappedDefaults = persistentDefaults ? [NSUserDefaults standardUserDefaults] : nil;
    return [[BGMUserDefaults alloc] initWithDefaults:wrappedDefaults];
}

- (void) initVolumesMenuSection {
    // Create the menu item with the (main) output volume slider.
    BGMOutputVolumeMenuItem* outputVolume =
            [[BGMOutputVolumeMenuItem alloc] initWithAudioDevices:audioDevices
                                                             view:self.outputVolumeView
                                                           slider:self.outputVolumeSlider
                                                      deviceLabel:self.outputVolumeLabel];
    [audioDevices setOutputVolumeMenuItem:outputVolume];

    NSInteger headingIdx = [self.bgmMenu indexOfItemWithTag:kVolumesHeadingMenuItemTag];

    // Add it to the main menu below the "Volumes" heading.
    [self.bgmMenu insertItem:outputVolume atIndex:(headingIdx + 1)];

    // Add the volume control for system (UI) sounds to the menu.
    BGMAudioDevice uiSoundsDevice = [audioDevices bgmDevice].GetUISoundsBGMDeviceInstance();

    systemSoundsVolume =
        [[BGMSystemSoundsVolume alloc] initWithUISoundsDevice:uiSoundsDevice
                                                         view:self.systemSoundsView
                                                       slider:self.systemSoundsSlider];

    [self.bgmMenu insertItem:systemSoundsVolume.menuItem atIndex:(headingIdx + 2)];

    // Add the app volumes to the menu.
    appVolumes = [[BGMAppVolumesController alloc] initWithMenu:self.bgmMenu
                                                 appVolumeView:self.appVolumeView
                                                  audioDevices:audioDevices];
}

- (void) applicationWillTerminate:(NSNotification*)aNotification {
    #pragma unused (aNotification)
    
    DebugMsg("BGMAppDelegate::applicationWillTerminate");

    // Change the user's default output device back.
    NSError* error = [audioDevices unsetBGMDeviceAsOSDefault];
    
    if (error) {
        [self showSetDeviceAsDefaultError:error
                                  message:@"Failed to reset your system's audio output device."
                          informativeText:@"You'll have to change it yourself to get audio working again."];
    }
}

#pragma mark Error messages

- (void) showBGMDeviceNotFoundErrorMessageAndExit {
    // BGMDevice wasn't found on the system. Most likely, BGMDriver isn't installed. Show an error
    // dialog and exit.
    //
    // TODO: Check whether the driver files are in /Library/Audio/Plug-Ins/HAL? Might even want to
    //       offer to install them if not.
    [self showErrorMessage:@"Could not find the Background Music virtual audio device."
           informativeText:@"Make sure you've installed Background Music Device.driver to "
                            "/Library/Audio/Plug-Ins/HAL and restarted coreaudiod (e.g. \"sudo "
                            "killall coreaudiod\")."
 exitAfterMessageDismissed:YES];
}

- (void) showFailedToSetOutputDeviceErrorMessage:(NSError*)error
                                 preferredDevice:(BGMAudioDevice)device {
    NSLog(@"Failed to set initial output device. Error: %@", error);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert alertWithError:BGMNN(error)];
        alert.messageText = @"Failed to set the output device.";

        NSString* __nullable name = nil;
        BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
            name = (__bridge NSString* __nullable)device.CopyName();
        });

        alert.informativeText =
                [NSString stringWithFormat:@"Could not start the device '%@'. (Error: %ld)",
                        name, error.code];

        [alert runModal];
    });
}

- (void) showOutputDeviceNotFoundErrorMessageAndExit {
    // We couldn't find any output devices. Show an error dialog and exit.
    [self showErrorMessage:@"Could not find an audio output device."
           informativeText:@"If you do have one installed, this is probably a bug. Sorry about "
                            "that. Feel free to file an issue on GitHub."
 exitAfterMessageDismissed:YES];
}

- (void) showXPCHelperErrorMessage:(NSError*)error {
    if (!haveShownXPCHelperErrorMessage) {
        haveShownXPCHelperErrorMessage = YES;
        
        // NSAlert should only be used on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert* alert = [NSAlert new];
            
            // TODO: Offer to install BGMXPCHelper if it's missing.
            // TODO: Show suppression button?
            [alert setMessageText:@"Error connecting to BGMXPCHelper."];
            [alert setInformativeText:[NSString stringWithFormat:@"%s%s%@ (%lu)",
                                       "Make sure you have BGMXPCHelper installed. There are instructions in the "
                                       "README.md file.\n\n"
                                       "Background Music might still work, but it won't work as well as it could.",
                                       "\n\nDetails:\n",
                                       [error localizedDescription],
                                       [error code]]];
            [alert runModal];
        });
    }
}

- (void) showErrorMessage:(NSString*)message
          informativeText:(NSString*)informativeText
exitAfterMessageDismissed:(BOOL)fatal {
    // NSAlert should only be used on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert new];
        [alert setMessageText:message];
        [alert setInformativeText:informativeText];

        // This crashes if built with Xcode 9.0.1, but works with versions of Xcode before 9 and
        // with 9.1.
        [alert runModal];

        if (fatal) {
            [NSApp terminate:self];
        }
    });
}

- (void) showSetDeviceAsDefaultError:(NSError*)error
                             message:(NSString*)msg
                     informativeText:(NSString*)info {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@ %@ Error: %@", msg, info, error);
        
        NSAlert* alert = [NSAlert alertWithError:error];
        alert.messageText = msg;
        alert.informativeText = info;
        
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Open Sound in System Preferences"];
        
        NSModalResponse buttonClicked = [alert runModal];
        
        if (buttonClicked != NSAlertFirstButtonReturn) {  // 'OK' is the first button.
            [self openSysPrefsSoundOutput];
        }
    });
}

- (void) openSysPrefsSoundOutput {
    SystemPreferencesApplication* __nullable sysPrefs =
        [SBApplication applicationWithBundleIdentifier:@"com.apple.systempreferences"];
    
    if (!sysPrefs) {
        NSLog(@"Could not open System Preferences");
        return;
    }
    
    // In System Preferences, go to the "Output" tab on the "Sound" pane.
    for (SystemPreferencesPane* pane : [sysPrefs panes]) {
        DebugMsg("BGMAppDelegate::openSysPrefsSoundOutput: pane = %s", [pane.name UTF8String]);
        
        if ([pane.id isEqualToString:@"com.apple.preference.sound"]) {
            sysPrefs.currentPane = pane;
            
            for (SystemPreferencesAnchor* anchor : [pane anchors]) {
                DebugMsg("BGMAppDelegate::openSysPrefsSoundOutput: anchor = %s", [anchor.name UTF8String]);
                
                if ([[anchor.name lowercaseString] isEqualToString:@"output"]) {
                    DebugMsg("BGMAppDelegate::openSysPrefsSoundOutput: Showing Output in Sound pane.");
                    
                    [anchor reveal];
                }
            }
        }
    }
    
    // Bring System Preferences to the foreground.
    [sysPrefs activate];
}

#pragma mark NSMenuDelegate

- (void) menuNeedsUpdate:(NSMenu*)menu {
    if ([menu isEqual:self.bgmMenu]) {
        [autoPauseMenuItem parentMenuNeedsUpdate];
    } else {
        DebugMsg("BGMAppDelegate::menuNeedsUpdate: Warning: unexpected menu. menu=%s", menu.description.UTF8String);
    }
}

- (void) menu:(NSMenu*)menu willHighlightItem:(NSMenuItem* __nullable)item {
    if ([menu isEqual:self.bgmMenu]) {
        [autoPauseMenuItem parentMenuItemWillHighlight:item];
    } else {
        DebugMsg("BGMAppDelegate::menu: Warning: unexpected menu. menu=%s", menu.description.UTF8String);
    }
}
@end

#pragma clang assume_nonnull end

