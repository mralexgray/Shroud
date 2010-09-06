//
//  FocusAppDelegate.m
//  Focus
//
//  Created by Nicholas Riley on 2/19/10.
//  Copyright 2010 Nicholas Riley. All rights reserved.
//

#import "FocusAppDelegate.h"
#import "FocusDockTileView.h"
#import "FocusNonactivatingView.h"
#import "FocusMenuBarView.h"
#import "FocusPreferencesController.h"
#import "NJRHotKey.h"
#import "NJRHotKeyManager.h"

#include <Carbon/Carbon.h>

@interface FocusAppDelegate ()
- (void)systemUIElementsDidBecomeVisible:(BOOL)visible;
@end

static OSStatus FocusSystemUIModeChanged(EventHandlerCallRef callRef, EventRef event, void *delegate) {
    UInt32 newMode = 0;
    OSStatus err;
    err = GetEventParameter(event, kEventParamSystemUIMode, typeUInt32, NULL, sizeof(UInt32), NULL, &newMode);
    if (err != noErr)
	return err;

    [(FocusAppDelegate *)delegate systemUIElementsDidBecomeVisible:newMode == kUIModeNormal];

    return noErr;
}

static void FocusGetScreenAndMenuBarFrames(NSRect *screenFrame, NSRect *menuBarFrame) {
    NSScreen *mainScreen = [NSScreen mainScreen];
    *screenFrame = *menuBarFrame = [mainScreen frame];
    NSRect visibleFrame = [mainScreen visibleFrame];
    CGFloat menuBarHeight = visibleFrame.size.height + visibleFrame.origin.y;

    menuBarFrame->origin.y += menuBarHeight;
    menuBarFrame->size.height -= menuBarHeight;
}

@implementation FocusAppDelegate

- (void)setUp;
{
    // Place Focus behind the frontmost application at launch.
    ProcessSerialNumber frontProcess;
    GetFrontProcess(&frontProcess);
    [NSApp unhideWithoutActivation];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidChangeScreenParameters:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:NSApp];

    // Bind the background color of windows & the Dock icon to the default.
    NSUserDefaultsController *userDefaultsController = [NSUserDefaultsController sharedUserDefaultsController];
    NSDictionary *colorBindingOptions = [NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:NSValueTransformerNameBindingOption];
    NSString *colorBindingKeyPath = [@"values." stringByAppendingString:FocusBackdropColorPreferenceKey];

    NSRect screenFrame, menuBarFrame;
    FocusGetScreenAndMenuBarFrames(&screenFrame, &menuBarFrame);

    // Create screen panel.
    screenPanel = [[NSPanel alloc] initWithContentRect:screenFrame
					     styleMask:NSBorderlessWindowMask | NSNonactivatingPanelMask
					       backing:NSBackingStoreBuffered
						 defer:NO];

    [screenPanel bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];
    [screenPanel setHasShadow:NO];

    [screenPanel setCollectionBehavior:
     (1 << 3 /*NSWindowCollectionBehaviorTransient*/) |
     (1 << 6 /*NSWindowCollectionBehaviorIgnoresCycle*/)];

    FocusNonactivatingView *view = [[[FocusNonactivatingView alloc] initWithFrame:[screenPanel frame]] autorelease];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    [screenPanel setContentView:view];

    [screenPanel orderFront:nil];

    // Create menu bar panel.
    menuBarPanel = [[NSPanel alloc] initWithContentRect:menuBarFrame
                                              styleMask:NSBorderlessWindowMask | NSNonactivatingPanelMask
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];

    [menuBarPanel bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];
    [menuBarPanel setHasShadow:NO];

    [menuBarPanel setIgnoresMouseEvents:YES];
    [menuBarPanel setLevel:kCGStatusWindowLevel + 1];

    FocusMenuBarView *menuBarView = [[[FocusMenuBarView alloc] initWithFrame:[menuBarPanel frame]] autorelease];
    [menuBarView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:[menuBarView frame] options:NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingActiveAlways owner:menuBarView userInfo:nil];
    [menuBarView addTrackingArea:area];
    [area release];

    [menuBarPanel setContentView:menuBarView];

    if (shouldCoverMenuBar)
        [menuBarPanel orderFront:nil];

    // Create dock tile.
    NSDockTile *dockTile = [NSApp dockTile];
    FocusDockTileView *dockTileView = [[FocusDockTileView alloc] initWithFrame:
                                       NSMakeRect(0, 0, dockTile.size.width, dockTile.size.height)];
    [dockTile setContentView:dockTileView];
    [dockTileView bind:@"backgroundColor" toObject:userDefaultsController withKeyPath:colorBindingKeyPath options:colorBindingOptions];

    // To avoid menubar flashing, we launch as a UIElement and transform ourselves when we're finished.
    ProcessSerialNumber currentProcess = { 0, kCurrentProcess };
    TransformProcessType(&currentProcess, kProcessTransformToForegroundApplication);

    SetFrontProcessWithOptions(&frontProcess, 0);

    static const EventTypeSpec eventSpecs[] = {{kEventClassApplication, kEventAppSystemUIModeChanged}};

    InstallApplicationEventHandler(NewEventHandlerUPP(FocusSystemUIModeChanged),
                                   GetEventTypeCount(eventSpecs),
                                   eventSpecs, self, NULL);

    // Register for shortcut changes.
    NSDictionary *hotKeyBindingOptions = [NSDictionary dictionaryWithObjectsAndKeys:@"NJRDictionaryToHotKeyTransformer", NSValueTransformerNameBindingOption,
        [NSNumber numberWithBool:YES], NSAllowsNullArgumentBindingOption,
        [NJRHotKey noHotKey], NSNullPlaceholderBindingOption,
        nil];
    // XXX whichever of these is first, the set method gets invoked twice at startup - why?
    [self bind:@"focusFrontmostApplicationShortcut" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:FocusFrontmostApplicationShortcutPreferenceKey] options:hotKeyBindingOptions];
    [self bind:@"focusFrontmostWindowShortcut" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:FocusFrontmostWindowShortcutPreferenceKey] options:hotKeyBindingOptions];
}

- (void)systemUIElementsDidBecomeVisible:(BOOL)visible;
{
    if (!shouldCoverMenuBar)
        return;

    if (!visible) {
	[menuBarPanel orderOut:nil];
	return;
    }

    // The OS will be fading in, so we do as well.
    [menuBarPanel setAlphaValue:0];
    [menuBarPanel orderFront:nil];

    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:0.2];
    [[menuBarPanel animator] setAlphaValue:1];
    [NSAnimationContext endGrouping];
}


- (void)setShouldCoverMenuBar:(BOOL)shouldCover;
{
    shouldCoverMenuBar = shouldCover;

    if (shouldCover)
        [menuBarPanel orderFront:nil];
    else
        [menuBarPanel orderOut:nil];
}

#pragma mark actions

static ProcessSerialNumber frontProcess;

- (void)restoreFrontProcessWindowOnly;
{
    SetFrontProcessWithOptions(&frontProcess, kSetFrontProcessFrontWindowOnly);
}

- (void)focusFrontmostApplicationWindowOnly:(BOOL)windowOnly;
{
    if ([NSApp isActive])
        return;

    GetFrontProcess(&frontProcess);

    if (windowOnly) {
        [NSApp unhideWithoutActivation];
        [NSApp activateIgnoringOtherApps:YES];
        // XXX can we get rid of this delay by using Carbon for unhiding ourself?
        [self performSelector:@selector(restoreFrontProcessWindowOnly) withObject:nil afterDelay: 0.05];
    } else {
        [NSApp unhideWithoutActivation];
        SetFrontProcessWithOptions(&frontProcess, 0);
    }
}

- (IBAction)focusFrontmostApplication:(id)sender;
{
    [self focusFrontmostApplicationWindowOnly:NO];
}

- (IBAction)focusFrontmostWindow:(id)sender;
{
    [self focusFrontmostApplicationWindowOnly:YES];
}

- (IBAction)orderFrontPreferencesPanel:(id)sender;
{
    if (preferencesController == nil)
        preferencesController = [[FocusPreferencesController alloc] init];

    [preferencesController showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];
}

#pragma mark systemwide shortcut support

- (void)setShortcutWithPreferenceKey:(NSString *)preferenceKey hotKey:(NJRHotKey *)hotKey action:(SEL)action;
{
    NJRHotKeyManager *hotKeyManager = [NJRHotKeyManager sharedManager];
    if ([hotKeyManager addShortcutWithIdentifier:preferenceKey hotKey:hotKey target:self action:action])
        return;

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:preferenceKey];
    NSRunAlertPanel(NSLocalizedString(@"Can't reserve shortcut", "Hot key set failure"),
                    NSLocalizedString(@"Focus was unable to reserve the shortcut %@. Please select another in Focus's Preferences.", "Hot key set failure"), nil, nil, nil, [hotKey keyGlyphs]);
    [self performSelector:@selector(orderFrontPreferencesPanel:) withObject:nil afterDelay:0.1];
}

- (void)setFocusFrontmostApplicationShortcut:(NJRHotKey *)hotKey;
{
    [self setShortcutWithPreferenceKey:FocusFrontmostApplicationShortcutPreferenceKey hotKey:hotKey action:@selector(focusFrontmostApplication:)];
}

- (void)setFocusFrontmostWindowShortcut:(NJRHotKey *)hotKey;
{
    [self setShortcutWithPreferenceKey:FocusFrontmostWindowShortcutPreferenceKey hotKey:hotKey action:@selector(focusFrontmostWindow:)];
}

// make KVC happy
- (NJRHotKey *)focusFrontmostApplicationShortcut { return nil; }
- (NJRHotKey *)focusFrontmostWindowShortcut { return nil; }

@end

@implementation FocusAppDelegate (NSApplicationNotifications)

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSUserDefaultsController *userDefaultsController = [NSUserDefaultsController sharedUserDefaultsController];

    [userDefaultsController setInitialValues:
     [NSDictionary dictionaryWithObject:[NSArchiver archivedDataWithRootObject:[NSColor colorWithCalibratedWhite:0.239 alpha:1.000]]
                                 forKey:FocusBackdropColorPreferenceKey]];

    [self bind:@"shouldCoverMenuBar" toObject:userDefaultsController withKeyPath:[@"values." stringByAppendingString:FocusShouldCoverMenuBarPreferenceKey] options:nil];

    [NSApp hide:nil];

    [self performSelector:@selector(setUp) withObject:nil afterDelay:0];
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification;
{
    NSRect screenFrame, menuBarFrame;
    FocusGetScreenAndMenuBarFrames(&screenFrame, &menuBarFrame);

    [screenPanel setFrame:screenFrame display:YES];
    [menuBarPanel setFrame:menuBarFrame display:YES];
}

@end

@implementation FocusAppDelegate (NSMenuValidation)

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
{
    SEL action = [menuItem action];

    if (action == @selector(focusFrontmostApplication:) ||
        action == @selector(focusFrontmostWindow:))
        return ![NSApp isActive];

    return YES;
}

@end
