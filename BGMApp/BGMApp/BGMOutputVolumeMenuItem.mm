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
//  BGMOutputVolumeMenuItem.mm
//  BGMApp
//
//  Copyright © 2017-2019 Kyle Neideck
//

// Self Include
#import "BGMOutputVolumeMenuItem.h"

// Local Includes
#import "BGM_Utils.h"
#import "BGMAudioDevice.h"
#import "BGMVolumeChangeListener.h"

// PublicUtility Includes
#import "CAException.h"
#import "CAPropertyAddress.h"

// System Includes
#import <CoreAudio/AudioHardware.h>


#pragma clang assume_nonnull begin

const float                    kSliderEpsilon           = 1e-10f;
const AudioObjectPropertyScope kScope                   = kAudioDevicePropertyScopeOutput;
NSString* const __nonnull      kGenericOutputDeviceName = @"Output Device";

@implementation BGMOutputVolumeMenuItem {
    BGMAudioDeviceManager* audioDevices;
    NSTextField* deviceLabel;
    NSSlider* volumeSlider;
    BGMAudioDevice outputDevice;
    BGMVolumeChangeListener* volumeChangeListener;
    AudioObjectPropertyListenerBlock updateLabelListenerBlock;
}

// TODO: Show the output device's icon next to its name.
// TODO: Should the menu (bgmMenu) hide after you change the output volume slider, like the normal
//       menu bar volume slider does?
// TODO: Move the output devices from Preferences to the main menu so they're slightly easier to
//       access?
// TODO: Update the screenshot in the README at some point.
- (instancetype) initWithAudioDevices:(BGMAudioDeviceManager*)devices
                                 view:(NSView*)view
                               slider:(NSSlider*)slider
                          deviceLabel:(NSTextField*)label {
    if ((self = [super initWithTitle:@"" action:nil keyEquivalent:@""])) {
        audioDevices = devices;
        deviceLabel = label;
        volumeSlider = slider;
        outputDevice = audioDevices.outputDevice;

        // volumeChangeListener and updateLabelListenerBlock are initialised in the methods called
        // below.

        // Apply our custom view from MainMenu.xib.
        self.view = view;

        // Set up the UI components in the view.
        [self initSlider];
        [self updateLabelAndToolTip];

        // Register a listener so we can update if the output device's data source changes.
        [self addOutputDeviceDataSourceListener];
    }

    return self;
}

- (void) dealloc {
    // Remove the audio property listeners.
    // TODO: This call isn't thread safe. (But currently this dealloc method is only called if
    //       there's an error.)
    [self removeOutputDeviceDataSourceListener];
}

- (void) initSlider {
    BGMAssert([NSThread isMainThread],
              "initSlider must be called from the main thread because it calls UI functions.");

    volumeSlider.target = self;
    volumeSlider.action = @selector(sliderChanged:);

    // Initialise the slider.
    [self updateVolumeSlider];

    // Register a listener that will update the slider when the user changes the volume or
    // mutes/unmutes their audio.
    BGMOutputVolumeMenuItem* __weak weakSelf = self;
    volumeChangeListener = new BGMVolumeChangeListener(audioDevices.bgmDevice, [=] {
        [weakSelf updateVolumeSlider];
    });
}

// Updates the value of the output volume slider. Should only be called on the main thread because
// it calls UI functions.
- (void) updateVolumeSlider {
    BGMAssert([[NSThread currentThread] isMainThread], "updateVolumeSlider on non-main thread.");

    BGMAudioDevice bgmDevice = [audioDevices bgmDevice];

    // BGMDevice should never return an error for these calls, so we just swallow any exceptions and
    // give up. (That said, we do check mute last so that, if it did throw, it wouldn't affect the
    // more important calls.)
    BGMLogAndSwallowExceptions("BGMOutputVolumeMenuItem::updateVolumeSlider", ([&] {
        BOOL hasVolume = bgmDevice.HasSettableMasterVolume(kScope);

        // If the device doesn't have a master volume control, we disable the slider and set it to
        // full (or to zero, if muted).
        volumeSlider.enabled = hasVolume;

        if (hasVolume) {
            // Set the slider to the current output volume. The slider values and volume values are
            // both from 0 to 1, so we can use the volume as is.
            volumeSlider.doubleValue =
                bgmDevice.GetVolumeControlScalarValue(kScope, kMasterChannel);
        } else {
            volumeSlider.doubleValue = 1.0;
        }

        // Set the slider to zero if the device is muted.
        if (bgmDevice.HasSettableMasterMute(kScope) &&
            bgmDevice.GetMuteControlValue(kScope, kMasterChannel)) {
            volumeSlider.doubleValue = 0.0;
        }
    }));
}

- (void) addOutputDeviceDataSourceListener {
    // Create the block that updates deviceLabel when the output device's data source changes, e.g.
    // from Internal Speakers to Headphones.
    if (!updateLabelListenerBlock) {
        BGMOutputVolumeMenuItem* __weak weakSelf = self;

        updateLabelListenerBlock =
            ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress* inAddresses) {
                // The docs for AudioObjectPropertyListenerBlock say inAddresses will always contain
                // at least one property the block is listening to, so there's no need to check it.
                #pragma unused (inNumberAddresses, inAddresses)
                [weakSelf updateLabelAndToolTip];
            };
    }

    // Register the listener.
    //
    // Instead of swallowing exceptions, we could try again later, but I doubt it would be worth the
    // effort. And the documentation doesn't actually explain what could cause this to fail.
    BGMLogAndSwallowExceptions("BGMOutputVolumeMenuItem::addOutputDeviceDataSourceListener", ([&] {
        outputDevice.AddPropertyListenerBlock(
            CAPropertyAddress(kAudioDevicePropertyDataSource, kScope),
            dispatch_get_main_queue(),
            updateLabelListenerBlock);
    }));
}

- (void) removeOutputDeviceDataSourceListener {
    BGMLogAndSwallowExceptions("BGMOutputVolumeMenuItem::removeOutputDeviceDataSourceListener",
                               ([&] {
        // Technically, there's a race here in that the device could be removed after we check it
        // exists, but before we try to remove the listener. We could check the error code of the
        // exception and not log an error message if the code is kAudioHardwareBadObjectError or
        // kAudioHardwareBadDeviceError, but it probably wouldn't be worth the effort.
        //
        // So for now the main reason for checking the device exists here is that it makes debug
        // builds much less likely to crash here. (They crash/break when an error is logged so it
        // will be noticed.)
        if (CAHALAudioObject::ObjectExists(outputDevice)) {
            outputDevice.RemovePropertyListenerBlock(
                CAPropertyAddress(kAudioDevicePropertyDataSource, kScope),
                dispatch_get_main_queue(),
                updateLabelListenerBlock);
        }
    }));
}

- (void) outputDeviceDidChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Remove the data source listener from the previous output device.
        [self removeOutputDeviceDataSourceListener];

        // Add it to the new output device.
        outputDevice = audioDevices.outputDevice;
        [self addOutputDeviceDataSourceListener];

        // Update the label to use the name of the new output device.
        [self updateLabelAndToolTip];

        // Set the slider to the volume of the new device.
        [self updateVolumeSlider];
    });
}

// Sets the label to the output device's name or, if it has one, its current datasource. If it has a
// datasource, the device's name is set as this menu item's tooltip. Falls back to a generic name if
// the device returns an error when queried.
- (void) updateLabelAndToolTip {
    if (outputDevice.GetObjectID() == kAudioObjectUnknown) {
        DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Output device unknown. Using the "
                 "generic label.");
        self.toolTip = nil;
        deviceLabel.stringValue = kGenericOutputDeviceName;
    } else {
        BOOL didSetLabel = NO;

        DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Output device: %u",
                 outputDevice.GetObjectID());

        try {
            if (outputDevice.HasDataSourceControl(kScope, kMasterChannel)) {
                DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Getting data source ID");
                // The device has datasources, so use the current datasource's name like macOS does.
                UInt32 dataSourceID = outputDevice.GetCurrentDataSourceID(kScope, kMasterChannel);

                DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: "
                         "Getting name for data source %u",
                         dataSourceID);
                deviceLabel.stringValue =
                    (__bridge_transfer NSString*)outputDevice.CopyDataSourceNameForID(
                        kScope, kMasterChannel, dataSourceID);

                // So we know not to change the text if setting the tooltip fails.
                didSetLabel = YES;

                DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Getting device name");
                // Set the tooltip of the menu item (the container) rather than the label because
                // menu items' tooltips will still appear when a different app is focused and, as
                // far as I know, BGMApp should never be the foreground app.
                self.toolTip = (__bridge_transfer NSString*)outputDevice.CopyName();
            } else {
                DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Getting device name");
                deviceLabel.stringValue = (__bridge_transfer NSString*)outputDevice.CopyName();
                self.toolTip = nil;
            }
        } catch (const CAException& e) {
            BGMLogException(e);

            // The device returned an error, so set the label to a generic device name, since we
            // don't want to leave it set to the previous device's name.
            self.toolTip = nil;

            if (!didSetLabel) {
                deviceLabel.stringValue = kGenericOutputDeviceName;
            }
        }
    }

    DebugMsg("BGMOutputVolumeMenuItem::updateLabelAndToolTip: Label: '%s' Tooltip: '%s'",
             deviceLabel.stringValue.UTF8String,
             self.toolTip.UTF8String);

    // Take the label out of the accessibility hierarchy, which also moves the slider up a level.
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101000  // MAC_OS_X_VERSION_10_10
    if ([deviceLabel.cell respondsToSelector:@selector(setAccessibilityElement:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
        deviceLabel.cell.accessibilityElement = NO;
#pragma clang diagnostic pop
    }
#endif
}

// Called when the user slides the slider.
- (IBAction) sliderChanged:(NSSlider*)sender {
    float newValue = sender.floatValue;

    DebugMsg("BGMOutputVolumeMenuItem::sliderChanged: New value: %f", newValue);

    // Update BGMDevice's volume to the new value selected by the user.
    try {
        // The slider values and volume values are both from 0.0f to 1.0f, so we can use the slider
        // value as is.
        audioDevices.bgmDevice.SetVolumeControlScalarValue(kScope, kMasterChannel, newValue);

        // Mute BGMDevice if they set the slider to zero, and unmute it for non-zero. Muting makes
        // sure the audio doesn't play very quietly instead being completely silent. This matches
        // the behaviour of the Volume menu built-in to macOS.
        if (audioDevices.bgmDevice.HasMuteControl(kScope, kMasterChannel)) {
            audioDevices.bgmDevice.SetMuteControlValue(kScope,
                                                       kMasterChannel,
                                                       (newValue < kSliderEpsilon));
        }
    } catch (const CAException& e) {
        NSLog(@"BGMOutputVolumeMenuItem::sliderChanged: Failed to set volume (%d)", e.GetError());
    }
}

@end

#pragma clang assume_nonnull end

