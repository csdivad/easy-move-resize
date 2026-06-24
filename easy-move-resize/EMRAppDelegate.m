#import "EMRAppDelegate.h"
#import "EMRMoveResize.h"
#import "EMRPreferences.h"

@interface EMRAppDelegate ()
- (AXUIElementRef)windowAtPoint:(CGPoint)point CF_RETURNS_RETAINED;
- (void)toggleZoomForWindow:(AXUIElementRef)window;
- (BOOL)restoreWindowIfMaximized:(AXUIElementRef)window mouseLocation:(CGPoint)mouseLocation updatedPosition:(NSPoint *)outPosition;
@end

@implementation EMRAppDelegate {
    EMRPreferences *preferences;
    NSMutableDictionary *_zoomRestoreFrames;
}

- (id) init  {
    self = [super init];
    if (self) {
        NSUserDefaults *userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"userPrefs"];
        preferences = [[EMRPreferences alloc] initWithUserDefaults:userDefaults];
        _zoomRestoreFrames = [[NSMutableDictionary alloc] init];
    }
    return self;
}

CGEventRef myCGEventCallback(CGEventTapProxy __unused proxy, CGEventType type, CGEventRef event, void *refcon) {

    EMRAppDelegate *ourDelegate = (__bridge EMRAppDelegate*)refcon;
    int keyModifierFlags = [ourDelegate modifierFlags];
    bool shouldMiddleClickResize = [ourDelegate shouldMiddleClickResize];
    bool resizeOnly = [ourDelegate resizeOnly];
    CGEventType resizeModifierDown = kCGEventRightMouseDown;
    CGEventType resizeModifierDragged = kCGEventRightMouseDragged;
    CGEventType resizeModifierUp = kCGEventRightMouseUp;
    bool handled = NO;

    if (![ourDelegate sessionActive]) {
        return event;
    }
    if (keyModifierFlags == 0) {
        // No modifier keys set. Disable behaviour.
        return event;
    }
    
    if (shouldMiddleClickResize){
        resizeModifierDown = kCGEventOtherMouseDown;
        resizeModifierDragged = kCGEventOtherMouseDragged;
        resizeModifierUp = kCGEventOtherMouseUp;
    }
    
    EMRMoveResize* moveResize = [EMRMoveResize instance];

    if ((type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput)) {
        // need to re-enable our eventTap (We got disabled.  Usually happens on a slow resizing app)
        CGEventTapEnable([moveResize eventTap], true);
        return event;
    }
    
    CGEventFlags flags = CGEventGetFlags(event);
    if ((flags & (keyModifierFlags)) != (keyModifierFlags)) {
        // didn't find our expected modifiers; this event isn't for us
        return event;
    }

    int ignoredKeysMask = (kCGEventFlagMaskShift | kCGEventFlagMaskCommand | kCGEventFlagMaskAlphaShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl | kCGEventFlagMaskSecondaryFn) ^ keyModifierFlags;
    
    if (flags & ignoredKeysMask) {
        // also ignore this event if we've got extra modifiers (i.e. holding down Cmd+Ctrl+Alt should not invoke our action)
        return event;
    }

    // Double-click with modifier keys: toggle maximize/restore (like double-clicking the title bar).
    if (type == kCGEventLeftMouseDown) {
        int64_t clickCount = CGEventGetIntegerValueField(event, kCGMouseEventClickState);
        if (clickCount == 2) {
            CGPoint mouseLocation = CGEventGetLocation(event);
            AXUIElementRef clickedWindow = [ourDelegate windowAtPoint:mouseLocation];
            if (clickedWindow != NULL) {
                pid_t pid;
                if (!AXUIElementGetPid(clickedWindow, &pid)) {
                    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
                    if ([[ourDelegate getDisabledApps] objectForKey:[app bundleIdentifier]] == nil) {
                        [ourDelegate toggleZoomForWindow:clickedWindow];
                    }
                }
                CFRelease(clickedWindow);
            }
            return NULL;
        }
    }

    if ((type == kCGEventLeftMouseDown && !resizeOnly)
            || type == resizeModifierDown) {
        CGPoint mouseLocation = CGEventGetLocation(event);
        [moveResize setTracking:CACurrentMediaTime()];

        AXUIElementRef _systemWideElement;
        AXUIElementRef _clickedWindow = NULL;
        _systemWideElement = AXUIElementCreateSystemWide();

        AXUIElementRef _element;
        if ((AXUIElementCopyElementAtPosition(_systemWideElement, (float) mouseLocation.x, (float) mouseLocation.y, &_element) == kAXErrorSuccess) && _element) {
            CFTypeRef _role;
            if (AXUIElementCopyAttributeValue(_element, (__bridge CFStringRef)NSAccessibilityRoleAttribute, &_role) == kAXErrorSuccess) {
                if ([(__bridge NSString *)_role isEqualToString:NSAccessibilityWindowRole]) {
                    _clickedWindow = _element;
                }
                if (_role != NULL) CFRelease(_role);
            }
            CFTypeRef _window;
            if (AXUIElementCopyAttributeValue(_element, (__bridge CFStringRef)NSAccessibilityWindowAttribute, &_window) == kAXErrorSuccess) {
                if (_element != NULL) CFRelease(_element);
                _clickedWindow = (AXUIElementRef)_window;
            }
        }
        CFRelease(_systemWideElement);
        
        pid_t PID;
        NSRunningApplication* app;
        if(!AXUIElementGetPid(_clickedWindow, &PID)) {
            app = [NSRunningApplication runningApplicationWithProcessIdentifier:PID];
            if ([[ourDelegate getDisabledApps] objectForKey:[app bundleIdentifier]] != nil) {
                [moveResize setTracking:0];
                return event;
            }
            [ourDelegate setMostRecentApp:app];
        }

        if([ourDelegate shouldBringWindowToFront]){
            if (app != nil) {
                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            }
            AXUIElementPerformAction(_clickedWindow, kAXRaiseAction);
        }
        
        CFTypeRef _cPosition = nil;
        NSPoint cTopLeft;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)_clickedWindow, (__bridge CFStringRef)NSAccessibilityPositionAttribute, &_cPosition) == kAXErrorSuccess) {
            if (!AXValueGetValue(_cPosition, kAXValueCGPointType, (void *)&cTopLeft)) {
                NSLog(@"ERROR: Could not decode position");
                cTopLeft = NSMakePoint(0, 0);
            }
            CFRelease(_cPosition);
        }
        
        cTopLeft.x = (int) cTopLeft.x;
        cTopLeft.y = (int) cTopLeft.y;

        [moveResize setWndPosition:cTopLeft];
        [moveResize setWindow:_clickedWindow];
        if (_clickedWindow != nil) CFRelease(_clickedWindow);

        if (type == kCGEventLeftMouseDown) {
            NSPoint restoredPosition;
            if ([ourDelegate restoreWindowIfMaximized:[moveResize window]
                                        mouseLocation:mouseLocation
                                      updatedPosition:&restoredPosition]) {
                [moveResize setWndPosition:restoredPosition];
            }
        }

        [moveResize startDisplayLink];
        handled = YES;
    }

    if (type == kCGEventLeftMouseDragged
            && [moveResize tracking] > 0) {
        double deltaX = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        double deltaY = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);

        NSPoint cTopLeft = [moveResize wndPosition];
        NSPoint thePoint;
        thePoint.x = cTopLeft.x + deltaX;
        thePoint.y = cTopLeft.y + deltaY;
        [moveResize setWndPosition:thePoint];
        [moveResize updatePosition:thePoint];
        // Intentionally not setting handled=YES: letting the event pass through
        // so the window server updates the cursor position. Without this, the
        // cursor visually freezes during a drag even though the window moves.
    }

    if (type == resizeModifierDown) {
        AXUIElementRef _clickedWindow = [moveResize window];

        // on resizeModifierDown click, record which direction we should resize in on the drag
        struct ResizeSection resizeSection;

        CGPoint clickPoint = CGEventGetLocation(event);

        NSPoint cTopLeft = [moveResize wndPosition];

        clickPoint.x -= cTopLeft.x;
        clickPoint.y -= cTopLeft.y;

        CFTypeRef _cSize;
        NSSize cSize;
        if (!(AXUIElementCopyAttributeValue((AXUIElementRef)_clickedWindow, (__bridge CFStringRef)NSAccessibilitySizeAttribute, &_cSize) == kAXErrorSuccess)
                || !AXValueGetValue(_cSize, kAXValueCGSizeType, (void *)&cSize)) {
            NSLog(@"ERROR: Could not decode size");
            return NULL;
        }
        CFRelease(_cSize);

        NSSize wndSize = cSize;

        if (clickPoint.x < wndSize.width/3) {
            resizeSection.xResizeDirection = left;
        } else if (clickPoint.x > 2*wndSize.width/3) {
            resizeSection.xResizeDirection = right;
        } else {
            resizeSection.xResizeDirection = noX;
        }

        if (clickPoint.y < wndSize.height/3) {
            resizeSection.yResizeDirection = bottom;
        } else  if (clickPoint.y > 2*wndSize.height/3) {
            resizeSection.yResizeDirection = top;
        } else {
            resizeSection.yResizeDirection = noY;
        }

        [moveResize setWndSize:wndSize];
        [moveResize setResizeSection:resizeSection];
        handled = YES;
    }

    if (type == resizeModifierDragged
            && [moveResize tracking] > 0) {
        struct ResizeSection resizeSection = [moveResize resizeSection];
        int deltaX = (int) CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
        int deltaY = (int) CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);

        NSPoint cTopLeft = [moveResize wndPosition];
        NSSize wndSize = [moveResize wndSize];

        switch (resizeSection.xResizeDirection) {
            case right:
                wndSize.width += deltaX;
                break;
            case left:
                wndSize.width -= deltaX;
                cTopLeft.x += deltaX;
                break;
            case noX:
                // nothing to do
                break;
            default:
                [NSException raise:@"Unknown xResizeSection" format:@"No case for %d", resizeSection.xResizeDirection];
        }

        switch (resizeSection.yResizeDirection) {
            case top:
                wndSize.height += deltaY;
                break;
            case bottom:
                wndSize.height -= deltaY;
                cTopLeft.y += deltaY;
                break;
            case noY:
                // nothing to do
                break;
            default:
                [NSException raise:@"Unknown yResizeSection" format:@"No case for %d", resizeSection.yResizeDirection];
        }

        [moveResize setWndPosition:cTopLeft];
        [moveResize setWndSize:wndSize];
        [moveResize updatePositionAndSize:cTopLeft size:wndSize resizeSection:resizeSection];
        // Intentionally not setting handled=YES: same cursor-freeze fix as the move drag above.
    }

    if ((type == kCGEventLeftMouseUp || type == resizeModifierUp)
        && [moveResize tracking] > 0) {
        [moveResize applyPendingChanges];
        [moveResize stopDisplayLink];
        [moveResize setTracking:0];
        handled = YES;
    }
    
    if (handled) {
        return NULL;
    }
    else {
        return event;
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    const void * keys[] = { kAXTrustedCheckOptionPrompt };
    const void * values[] = { kCFBooleanTrue };

    CFDictionaryRef options = CFDictionaryCreate(
            kCFAllocatorDefault,
            keys,
            values,
            sizeof(keys) / sizeof(*keys),
            &kCFCopyStringDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);

    if (!AXIsProcessTrustedWithOptions(options)) {
        // don't have permission to do our thing right now... AXIsProcessTrustedWithOptions prompted the user to fix
        // this, so hopefully on next launch we'll be good to go
        NSLog(@"Missing permissions");
        exit(1);
    }
    
    [self initMenuItems];

    // Retrieve the Key press modifier flags to activate move/resize actions.
    keyModifierFlags = [preferences modifierFlags];
    
    CFRunLoopSourceRef runLoopSource;

    CGEventMask eventMask = CGEventMaskBit( kCGEventLeftMouseDown )
                    | CGEventMaskBit( kCGEventRightMouseDown )
                    | CGEventMaskBit( kCGEventOtherMouseDown )
                    | CGEventMaskBit( kCGEventLeftMouseDragged )
                    | CGEventMaskBit( kCGEventRightMouseDragged )
                    | CGEventMaskBit( kCGEventOtherMouseDragged )
                    | CGEventMaskBit( kCGEventLeftMouseUp )
                    | CGEventMaskBit( kCGEventRightMouseUp )
                    | CGEventMaskBit( kCGEventOtherMouseUp )
    ;

    CFMachPortRef eventTap = CGEventTapCreate(kCGHIDEventTap,
                                              kCGHeadInsertEventTap,
                                              kCGEventTapOptionDefault,
                                              eventMask,
                                              myCGEventCallback,
                                              (__bridge void * _Nullable)self);

    if (!eventTap) {
        NSLog(@"Couldn't create event tap!");
        exit(1);
    }

    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);


    EMRMoveResize *moveResize = [EMRMoveResize instance];
    [moveResize setEventTap:eventTap];
    [moveResize setRunLoopSource:runLoopSource];
    [self enableRunLoopSource:moveResize];
    CFRelease(runLoopSource);
    [moveResize setupDisplayLink];

    _sessionActive = true;
    [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:self
            selector:@selector(becameActive:)
            name:NSWorkspaceSessionDidBecomeActiveNotification
            object:nil];

    [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:self
            selector:@selector(becameInactive:)
            name:NSWorkspaceSessionDidResignActiveNotification
            object:nil];

    [[NSNotificationCenter defaultCenter]
            addObserver:self
            selector:@selector(screensDidChange:)
            name:NSApplicationDidChangeScreenParametersNotification
            object:nil];
    
    [self reconstructDisabledAppsSubmenu];
}

- (void)becameActive:(NSNotification*) notification {
    _sessionActive = true;
}

- (void)becameInactive:(NSNotification*) notification {
    _sessionActive = false;
}

- (void)screensDidChange:(NSNotification*) notification {
    [[EMRMoveResize instance] setupDisplayLink];
}

-(void)awakeFromNib{
    NSImage *icon = [NSImage imageNamed:@"MenuIcon"];
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [statusItem setMenu:statusMenu];
    [statusItem setImage:icon];
    [statusMenu setAutoenablesItems:NO];
    [[statusMenu itemAtIndex:0] setEnabled:NO];
}

- (void)enableRunLoopSource:(EMRMoveResize*)moveResize {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), [moveResize runLoopSource], kCFRunLoopCommonModes);
    CGEventTapEnable([moveResize eventTap], true);
}

- (void)disableRunLoopSource:(EMRMoveResize*)moveResize {
    CGEventTapEnable([moveResize eventTap], false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), [moveResize runLoopSource], kCFRunLoopCommonModes);
}

- (void)initMenuItems {
    [_altMenu setState:0];
    [_cmdMenu setState:0];
    [_ctrlMenu setState:0];
    [_shiftMenu setState:0];
    [_fnMenu setState:0];
    [_disabledMenu setState:0];
    [_bringWindowFrontMenu setState:0];
    [_middleClickResizeMenu setState:0];

    bool shouldBringWindowToFront = [preferences shouldBringWindowToFront];
    bool shouldMiddleClickResize = [preferences shouldMiddleClickResize];
    bool resizeOnly = [preferences resizeOnly];

    if(shouldBringWindowToFront){
        [_bringWindowFrontMenu setState:1];
    }
    if(shouldMiddleClickResize){
        [_middleClickResizeMenu setState:1];
    }
    if(resizeOnly){
        [_resizeOnlyMenu setState:1];
    }
    
    NSSet* flags = [preferences getFlagStringSet];
    if ([flags containsObject:ALT_KEY]) {
        [_altMenu setState:1];
    }
    if ([flags containsObject:CMD_KEY]) {
        [_cmdMenu setState:1];
    }
    if ([flags containsObject:CTRL_KEY]) {
        [_ctrlMenu setState:1];
    }
    if ([flags containsObject:SHIFT_KEY]) {
        [_shiftMenu setState:1];
    }
    if ([flags containsObject:FN_KEY]) {
        [_fnMenu setState:1];
    }
}

- (IBAction)modifierToggle:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    BOOL newState = ![menu state];
    [menu setState:newState];
    [preferences setModifierKey:[menu title] enabled:newState];
    keyModifierFlags = [preferences modifierFlags];
}

- (IBAction)resetToDefaults:(id)sender {
    EMRMoveResize* moveResize = [EMRMoveResize instance];
    [preferences setToDefaults];
    [self initMenuItems];
    [self setMenusEnabled:YES];
    [self enableRunLoopSource:moveResize];
    keyModifierFlags = [preferences modifierFlags];
}

- (IBAction)toggleBringWindowToFront:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    BOOL newState = ![menu state];
    [menu setState:newState];
    [preferences setShouldBringWindowToFront:newState];
}

- (IBAction)toggleMiddleClickResize:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    BOOL newState = ![menu state];
    [menu setState:newState];
    [preferences setShouldMiddleClickResize:newState];
}

- (IBAction)toggleDisabled:(id)sender {
    EMRMoveResize* moveResize = [EMRMoveResize instance];
    if ([_disabledMenu state] == 0) {
        // We are enabled, disable
        [_disabledMenu setState:YES];
        [self setMenusEnabled:NO];
        [self disableRunLoopSource:moveResize];
    }
    else {
        // We are disabled, enable
        [_disabledMenu setState:NO];
        [self setMenusEnabled:YES];
        [self enableRunLoopSource:moveResize];
    }
}

- (IBAction)toggleResizeOnly:(id)sender {
    NSMenuItem *menu = (NSMenuItem*)sender;
    BOOL newState = ![menu state];
    [menu setState:newState];
    [preferences setResizeOnly:newState];
}

- (IBAction)disableLastApp:(id)sender {
    [preferences setDisabledForApp:[lastApp bundleIdentifier] withLocalizedName:[lastApp localizedName] disabled:YES];
    [_lastAppMenu setEnabled:FALSE];
    [self reconstructDisabledAppsSubmenu];
}

- (IBAction)enableDisabledApp:(id)sender {
    NSString *bundleId = [sender representedObject];
    [preferences setDisabledForApp:bundleId withLocalizedName:nil disabled:NO];
    if (lastApp != nil && [[lastApp bundleIdentifier] isEqualToString:bundleId]) {
        [_lastAppMenu setEnabled:YES];
    }
    [self reconstructDisabledAppsSubmenu];
}

- (int)modifierFlags {
    return keyModifierFlags;
}
- (void) setMostRecentApp:(NSRunningApplication*)app {
    lastApp = app;
    [_lastAppMenu setTitle:[NSString stringWithFormat:@"Disable for %@", [app localizedName]]];
    [_lastAppMenu setEnabled:YES];
}
- (NSDictionary*) getDisabledApps {
    return [preferences getDisabledApps];
}
-(BOOL)shouldBringWindowToFront {
    return [preferences shouldBringWindowToFront];
}
-(BOOL)shouldMiddleClickResize {
    return [preferences shouldMiddleClickResize];
}
-(BOOL)resizeOnly {
    return [preferences resizeOnly];
}

- (void)setMenusEnabled:(BOOL)enabled {
    [_altMenu setEnabled:enabled];
    [_cmdMenu setEnabled:enabled];
    [_ctrlMenu setEnabled:enabled];
    [_shiftMenu setEnabled:enabled];
    [_fnMenu setEnabled:enabled];
    [_bringWindowFrontMenu setEnabled:enabled];
    [_middleClickResizeMenu setEnabled:enabled];
}

- (void)reconstructDisabledAppsSubmenu {
    NSMenu *submenu = [[NSMenu alloc] init];
    NSDictionary *disabledApps = [self getDisabledApps];
    for (id bundleIdentifier in disabledApps) {
        NSMenuItem *item = [submenu addItemWithTitle:[disabledApps objectForKey:bundleIdentifier] action:@selector(enableDisabledApp:) keyEquivalent:@""];
        [item setRepresentedObject:bundleIdentifier];
    }
    [_disabledAppsMenu setSubmenu:submenu];
    [_disabledAppsMenu setEnabled:([disabledApps count] > 0)];
}

// Returns a retained reference to the window element at the given Quartz point, or NULL.
- (AXUIElementRef)windowAtPoint:(CGPoint)point CF_RETURNS_RETAINED {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef result = NULL;
    AXUIElementRef element = NULL;

    if (AXUIElementCopyElementAtPosition(systemWide, (float)point.x, (float)point.y, &element) == kAXErrorSuccess && element != NULL) {
        CFTypeRef windowRef = NULL;
        if (AXUIElementCopyAttributeValue(element, (__bridge CFStringRef)NSAccessibilityWindowAttribute, &windowRef) == kAXErrorSuccess && windowRef != NULL) {
            result = (AXUIElementRef)windowRef;
        } else {
            CFTypeRef role = NULL;
            if (AXUIElementCopyAttributeValue(element, (__bridge CFStringRef)NSAccessibilityRoleAttribute, &role) == kAXErrorSuccess) {
                if (role != NULL && [(__bridge NSString *)role isEqualToString:NSAccessibilityWindowRole]) {
                    result = (AXUIElementRef)CFRetain(element);
                }
                if (role != NULL) CFRelease(role);
            }
        }
        CFRelease(element);
    }
    CFRelease(systemWide);
    return result;
}

// Toggles a window between filling the screen's visible area and its previous frame.
// AX window positions use Quartz coordinates (origin at top-left of primary screen).
// NSScreen uses AppKit coordinates (origin at bottom-left of primary screen).
- (void)toggleZoomForWindow:(AXUIElementRef)window {
    CFTypeRef posRef = nil;
    NSPoint currentPos = NSZeroPoint;
    if (AXUIElementCopyAttributeValue(window, (__bridge CFStringRef)NSAccessibilityPositionAttribute, &posRef) == kAXErrorSuccess) {
        AXValueGetValue((AXValueRef)posRef, kAXValueCGPointType, (void *)&currentPos);
        CFRelease(posRef);
    }

    CFTypeRef sizeRef = nil;
    NSSize currentSize = NSZeroSize;
    if (AXUIElementCopyAttributeValue(window, (__bridge CFStringRef)NSAccessibilitySizeAttribute, &sizeRef) == kAXErrorSuccess) {
        AXValueGetValue((AXValueRef)sizeRef, kAXValueCGSizeType, (void *)&currentSize);
        CFRelease(sizeRef);
    }

    if (NSEqualSizes(currentSize, NSZeroSize)) return;

    // Find which screen the window is on by its center point.
    CGFloat primaryHeight = [[[NSScreen screens] firstObject] frame].size.height;
    NSPoint windowCenterCocoa = NSMakePoint(currentPos.x + currentSize.width / 2.0,
                                             primaryHeight - currentPos.y - currentSize.height / 2.0);
    NSScreen *targetScreen = [NSScreen mainScreen];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(windowCenterCocoa, [screen frame])) {
            targetScreen = screen;
            break;
        }
    }

    // Convert the screen's visible frame to Quartz coordinates.
    NSRect cocoaVisible = [targetScreen visibleFrame];
    NSPoint maxPos = NSMakePoint(cocoaVisible.origin.x,
                                  primaryHeight - cocoaVisible.origin.y - cocoaVisible.size.height);
    NSSize maxSize = cocoaVisible.size;

    const CGFloat kTolerance = 4.0;
    BOOL isMaximized = (fabs(currentPos.x - maxPos.x) < kTolerance &&
                        fabs(currentPos.y - maxPos.y) < kTolerance &&
                        fabs(currentSize.width - maxSize.width) < kTolerance &&
                        fabs(currentSize.height - maxSize.height) < kTolerance);

    pid_t pid;
    AXUIElementGetPid(window, &pid);
    NSNumber *key = @(pid);

    NSPoint newPos;
    NSSize newSize;

    if (isMaximized) {
        NSValue *savedFrame = _zoomRestoreFrames[key];
        if (savedFrame == nil) return;
        NSRect restoreRect = [savedFrame rectValue];
        newPos = restoreRect.origin;
        newSize = restoreRect.size;
        [_zoomRestoreFrames removeObjectForKey:key];
    } else {
        _zoomRestoreFrames[key] = [NSValue valueWithRect:NSMakeRect(currentPos.x, currentPos.y,
                                                                     currentSize.width, currentSize.height)];
        newPos = maxPos;
        newSize = maxSize;
    }

    CFTypeRef posValue = AXValueCreate(kAXValueCGPointType, (const void *)&newPos);
    AXUIElementSetAttributeValue(window, (__bridge CFStringRef)NSAccessibilityPositionAttribute, posValue);
    CFRelease(posValue);

    CFTypeRef sizeValue = AXValueCreate(kAXValueCGSizeType, (const void *)&newSize);
    AXUIElementSetAttributeValue(window, (__bridge CFStringRef)NSAccessibilitySizeAttribute, sizeValue);
    CFRelease(sizeValue);
}

// When a move drag starts on a maximized window, restores it to the pre-maximize size
// and repositions so the cursor stays at the same relative horizontal position.
// Returns YES and writes the new top-left into outPosition if a restore was performed.
- (BOOL)restoreWindowIfMaximized:(AXUIElementRef)window
                   mouseLocation:(CGPoint)mouseLocation
                 updatedPosition:(NSPoint *)outPosition {
    CFTypeRef posRef = nil;
    NSPoint currentPos = NSZeroPoint;
    if (AXUIElementCopyAttributeValue(window, (__bridge CFStringRef)NSAccessibilityPositionAttribute, &posRef) != kAXErrorSuccess) return NO;
    AXValueGetValue((AXValueRef)posRef, kAXValueCGPointType, (void *)&currentPos);
    CFRelease(posRef);

    CFTypeRef sizeRef = nil;
    NSSize currentSize = NSZeroSize;
    if (AXUIElementCopyAttributeValue(window, (__bridge CFStringRef)NSAccessibilitySizeAttribute, &sizeRef) != kAXErrorSuccess) return NO;
    AXValueGetValue((AXValueRef)sizeRef, kAXValueCGSizeType, (void *)&currentSize);
    CFRelease(sizeRef);

    if (currentSize.width <= 0 || currentSize.height <= 0) return NO;

    CGFloat ratioX = (mouseLocation.x - currentPos.x) / currentSize.width;
    ratioX = fmax(0.0, fmin(1.0, ratioX));

    CGFloat primaryHeight = [[[NSScreen screens] firstObject] frame].size.height;
    NSPoint windowCenterCocoa = NSMakePoint(currentPos.x + currentSize.width / 2.0,
                                             primaryHeight - currentPos.y - currentSize.height / 2.0);
    NSScreen *targetScreen = [NSScreen mainScreen];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(windowCenterCocoa, [screen frame])) {
            targetScreen = screen;
            break;
        }
    }
    NSRect cocoaVisible = [targetScreen visibleFrame];
    NSPoint maxPos = NSMakePoint(cocoaVisible.origin.x,
                                  primaryHeight - cocoaVisible.origin.y - cocoaVisible.size.height);
    NSSize maxSize = cocoaVisible.size;

    const CGFloat kTolerance = 4.0;
    BOOL isCustomMaximized = (fabs(currentPos.x - maxPos.x) < kTolerance &&
                               fabs(currentPos.y - maxPos.y) < kTolerance &&
                               fabs(currentSize.width - maxSize.width) < kTolerance &&
                               fabs(currentSize.height - maxSize.height) < kTolerance);
    if (!isCustomMaximized) return NO;

    pid_t pid;
    AXUIElementGetPid(window, &pid);
    NSValue *savedFrame = _zoomRestoreFrames[@(pid)];
    if (savedFrame == nil) return NO;

    NSRect restoreRect = [savedFrame rectValue];
    if (restoreRect.size.width <= 0 || restoreRect.size.height <= 0) return NO;

    NSPoint newPos = NSMakePoint(mouseLocation.x - ratioX * restoreRect.size.width, mouseLocation.y);

    CFTypeRef posValue = AXValueCreate(kAXValueCGPointType, (const void *)&newPos);
    AXUIElementSetAttributeValue(window, (__bridge CFStringRef)NSAccessibilityPositionAttribute, posValue);
    CFRelease(posValue);

    CFTypeRef sizeValue = AXValueCreate(kAXValueCGSizeType, (const void *)&restoreRect.size);
    AXUIElementSetAttributeValue(window, (__bridge CFStringRef)NSAccessibilitySizeAttribute, sizeValue);
    CFRelease(sizeValue);

    [_zoomRestoreFrames removeObjectForKey:@(pid)];
    *outPosition = newPos;
    return YES;
}

@end
