// SHE library
// Copyright (C) 2015-2016  David Capello
//
// This file is released under the terms of the MIT license.
// Read LICENSE.txt for more information.

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "she/osx/view.h"

#include "gfx/point.h"
#include "she/event.h"
#include "she/event_queue.h"
#include "she/keys.h"
#include "she/osx/generate_drop_files.h"
#include "she/osx/window.h"
#include "she/system.h"

#include <Carbon/Carbon.h>      // For VK codes

namespace she {

bool osx_is_key_pressed(KeyScancode scancode);

namespace {

// Internal array of pressed keys used in isKeyPressed()
int g_pressedKeys[kKeyScancodes];
bool g_translateDeadKeys = false;
UInt32 g_lastDeadKeyState = 0;

gfx::Point get_local_mouse_pos(NSView* view, NSEvent* event)
{
  NSPoint point = [view convertPoint:[event locationInWindow]
                            fromView:nil];
  int scale = 1;
  if ([view window])
    scale = [(OSXWindow*)[view window] scale];

  // "she" layer coordinates expect (X,Y) origin at the top-left corner.
  return gfx::Point(point.x / scale,
                    (view.bounds.size.height - point.y) / scale);
}

Event::MouseButton get_mouse_buttons(NSEvent* event)
{
  // Some Wacom drivers on OS X report right-clicks with
  // buttonNumber=0, so we've to check the type event anyway.
  switch (event.type) {
    case NSLeftMouseDown:
    case NSLeftMouseUp:
    case NSLeftMouseDragged:
      return Event::LeftButton;
    case NSRightMouseDown:
    case NSRightMouseUp:
    case NSRightMouseDragged:
      return Event::RightButton;
  }

  switch ([event buttonNumber]) {
    case 0: return Event::LeftButton; break;
    case 1: return Event::RightButton; break;
    case 2: return Event::MiddleButton; break;
    // TODO add support for other buttons
  }
  return Event::MouseButton::NoneButton;
}

KeyModifiers get_modifiers_from_nsevent(NSEvent* event)
{
  int modifiers = kKeyNoneModifier;
  NSEventModifierFlags nsFlags = event.modifierFlags;
  if (nsFlags & NSShiftKeyMask) modifiers |= kKeyShiftModifier;
  if (nsFlags & NSControlKeyMask) modifiers |= kKeyCtrlModifier;
  if (nsFlags & NSAlternateKeyMask) modifiers |= kKeyAltModifier;
  if (nsFlags & NSCommandKeyMask) modifiers |= kKeyCmdModifier;
  if (osx_is_key_pressed(kKeySpace)) modifiers |= kKeySpaceModifier;
  return (KeyModifiers)modifiers;
}

// Based on code from:
// http://stackoverflow.com/questions/22566665/how-to-capture-unicode-from-key-events-without-an-nstextview
// http://stackoverflow.com/questions/12547007/convert-key-code-into-key-equivalent-string
// http://stackoverflow.com/questions/8263618/convert-virtual-key-code-to-unicode-string
//
// It includes a "translateDeadKeys" flag to avoid processing dead
// keys in case that we want to use key
CFStringRef get_unicode_from_key_code(NSEvent* event,
                                      const bool translateDeadKeys)
{
  // The "TISCopyCurrentKeyboardInputSource()" doesn't contain
  // kTISPropertyUnicodeKeyLayoutData (returns nullptr) when the input
  // source is Japanese (Romaji/Hiragana/Katakana).

  //TISInputSourceRef inputSource = TISCopyCurrentKeyboardInputSource();
  TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
  CFDataRef keyLayoutData = (CFDataRef)TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
  const UCKeyboardLayout* keyLayout =
    (keyLayoutData ? (const UCKeyboardLayout*)CFDataGetBytePtr(keyLayoutData): nullptr);

  UInt32 deadKeyState = (translateDeadKeys ? g_lastDeadKeyState: 0);
  UniChar output[4];
  UniCharCount length;

  // Reference here:
  // https://developer.apple.com/reference/coreservices/1390584-uckeytranslate?language=objc
  UCKeyTranslate(
    keyLayout,
    event.keyCode,
    kUCKeyActionDown,
    ((event.modifierFlags >> 16) & 0xFF),
    LMGetKbdType(),
    (translateDeadKeys ? 0: kUCKeyTranslateNoDeadKeysMask),
    &deadKeyState,
    sizeof(output) / sizeof(output[0]),
    &length,
    output);

  if (translateDeadKeys)
    g_lastDeadKeyState = deadKeyState;

  CFRelease(inputSource);
  return CFStringCreateWithCharacters(kCFAllocatorDefault, output, length);
}

} // anonymous namespace

bool osx_is_key_pressed(KeyScancode scancode)
{
  if (scancode >= 0 && scancode < kKeyScancodes)
    return (g_pressedKeys[scancode] != 0);
  else
    return false;
}

int osx_get_unicode_from_scancode(KeyScancode scancode)
{
  if (scancode >= 0 && scancode < kKeyScancodes)
    return g_pressedKeys[scancode];
  else
    return 0;
}

} // namespace she

using namespace she;

@implementation OSXView

- (id)initWithFrame:(NSRect)frameRect
{
  // We start without the system mouse cursor
  m_nsCursor = nil;
  m_visibleMouse = true;
  m_pointerType = she::PointerType::Unknown;

  self = [super initWithFrame:frameRect];
  if (self != nil) {
    [self createMouseTrackingArea];
    [self registerForDraggedTypes:
      [NSArray arrayWithObjects:
        NSFilenamesPboardType,
        nil]];
  }
  return self;
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (void)viewDidHide
{
  [super viewDidHide];
  [self destroyMouseTrackingArea];
}

- (void)viewDidUnhide
{
  [super viewDidUnhide];
  [self createMouseTrackingArea];
}

- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];

  if ([self window]) {
    OSXWindowImpl* impl = [((OSXWindow*)[self window]) impl];
    if (impl)
      impl->onWindowChanged();
  }
}

- (void)drawRect:(NSRect)dirtyRect
{
  [super drawRect:dirtyRect];

  if ([self window]) {
    OSXWindowImpl* impl = [((OSXWindow*)[self window]) impl];
    if (impl)
      impl->onDrawRect(gfx::Rect(dirtyRect.origin.x,
                                 dirtyRect.origin.y,
                                 dirtyRect.size.width,
                                 dirtyRect.size.height));
  }
}

- (void)keyDown:(NSEvent*)event
{
  [super keyDown:event];

  KeyScancode scancode = cocoavk_to_scancode(event.keyCode);
  Event ev;
  ev.setType(Event::KeyDown);
  ev.setScancode(scancode);
  ev.setModifiers(get_modifiers_from_nsevent(event));
  ev.setRepeat(event.ARepeat ? 1: 0);
  ev.setUnicodeChar(0);

  bool sendMsg = true;

  CFStringRef strRef = get_unicode_from_key_code(event, false);
  if (strRef) {
    int length = CFStringGetLength(strRef);
    if (length == 1)
      ev.setUnicodeChar(CFStringGetCharacterAtIndex(strRef, 0));
    CFRelease(strRef);
  }

  if (scancode >= 0 && scancode < kKeyScancodes)
    g_pressedKeys[scancode] = (ev.unicodeChar() ? ev.unicodeChar(): 1);

  if (g_translateDeadKeys) {
    strRef = get_unicode_from_key_code(event, true);
    if (strRef) {
      int length = CFStringGetLength(strRef);
      if (length > 0) {
        sendMsg = false;
        for (int i=0; i<length; ++i) {
          ev.setUnicodeChar(CFStringGetCharacterAtIndex(strRef, i));
          queue_event(ev);
        }
        g_lastDeadKeyState = 0;
      }
      else {
        ev.setDeadKey(true);
      }
      CFRelease(strRef);
    }
  }

  if (sendMsg)
    queue_event(ev);
}

- (void)keyUp:(NSEvent*)event
{
  [super keyUp:event];

  KeyScancode scancode = cocoavk_to_scancode(event.keyCode);
  if (scancode >= 0 && scancode < kKeyScancodes)
    g_pressedKeys[scancode] = 0;

  Event ev;
  ev.setType(Event::KeyUp);
  ev.setScancode(scancode);
  ev.setModifiers(get_modifiers_from_nsevent(event));
  ev.setRepeat(event.ARepeat ? 1: 0);
  ev.setUnicodeChar(0);

  queue_event(ev);
}

- (void)flagsChanged:(NSEvent*)event
{
  [super flagsChanged:event];
  [OSXView updateKeyFlags:event];
}

+ (void)updateKeyFlags:(NSEvent*)event
{
  static int lastFlags = 0;
  static int flags[] = {
    NSShiftKeyMask,
    NSControlKeyMask,
    NSAlternateKeyMask,
    NSCommandKeyMask
  };
  static KeyScancode scancodes[] = {
    kKeyLShift,
    kKeyLControl,
    kKeyAlt,
    kKeyCommand
  };

  KeyModifiers modifiers = get_modifiers_from_nsevent(event);
  int newFlags = event.modifierFlags;

  for (int i=0; i<sizeof(flags)/sizeof(flags[0]); ++i) {
    if ((lastFlags & flags[i]) != (newFlags & flags[i])) {
      Event ev;
      ev.setType(
        ((newFlags & flags[i]) != 0 ? Event::KeyDown:
                                      Event::KeyUp));

      g_pressedKeys[scancodes[i]] = ((newFlags & flags[i]) != 0);

      ev.setScancode(scancodes[i]);
      ev.setModifiers(modifiers);
      ev.setRepeat(0);
      queue_event(ev);
    }
  }

  lastFlags = newFlags;
}

- (void)mouseEntered:(NSEvent*)event
{
  [self updateCurrentCursor];

  Event ev;
  ev.setType(Event::MouseEnter);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setModifiers(get_modifiers_from_nsevent(event));
  queue_event(ev);
}

- (void)mouseMoved:(NSEvent*)event
{
  Event ev;
  ev.setType(Event::MouseMove);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setModifiers(get_modifiers_from_nsevent(event));

  if (m_pointerType != she::PointerType::Unknown)
    ev.setPointerType(m_pointerType);

  queue_event(ev);
}

- (void)mouseExited:(NSEvent*)event
{
  // Restore arrow cursor
  if (!m_visibleMouse) {
    m_visibleMouse = true;
    [NSCursor unhide];
  }
  [[NSCursor arrowCursor] set];

  Event ev;
  ev.setType(Event::MouseLeave);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setModifiers(get_modifiers_from_nsevent(event));
  queue_event(ev);
}

- (void)mouseDown:(NSEvent*)event
{
  [self handleMouseDown:event];
}

- (void)mouseUp:(NSEvent*)event
{
  [self handleMouseUp:event];
}

- (void)mouseDragged:(NSEvent*)event
{
  [self handleMouseDragged:event];
}

- (void)rightMouseDown:(NSEvent*)event
{
  [self handleMouseDown:event];
}

- (void)rightMouseUp:(NSEvent*)event
{
  [self handleMouseUp:event];
}

- (void)rightMouseDragged:(NSEvent*)event
{
  [self handleMouseDragged:event];
}

- (void)otherMouseDown:(NSEvent*)event
{
  [self handleMouseDown:event];
}

- (void)otherMouseUp:(NSEvent*)event
{
  [self handleMouseUp:event];
}

- (void)otherMouseDragged:(NSEvent*)event
{
  [self handleMouseDragged:event];
}

- (void)handleMouseDown:(NSEvent*)event
{
  Event ev;
  ev.setType(event.clickCount == 2 ? Event::MouseDoubleClick:
                                     Event::MouseDown);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setButton(get_mouse_buttons(event));
  ev.setModifiers(get_modifiers_from_nsevent(event));

  if (m_pointerType != she::PointerType::Unknown)
    ev.setPointerType(m_pointerType);

  queue_event(ev);
}

- (void)handleMouseUp:(NSEvent*)event
{
  Event ev;
  ev.setType(Event::MouseUp);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setButton(get_mouse_buttons(event));
  ev.setModifiers(get_modifiers_from_nsevent(event));

  if (m_pointerType != she::PointerType::Unknown)
    ev.setPointerType(m_pointerType);

  queue_event(ev);
}

- (void)handleMouseDragged:(NSEvent*)event
{
  Event ev;
  ev.setType(Event::MouseMove);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setButton(get_mouse_buttons(event));
  ev.setModifiers(get_modifiers_from_nsevent(event));

  if (m_pointerType != she::PointerType::Unknown)
    ev.setPointerType(m_pointerType);

  queue_event(ev);
}

- (void)setFrameSize:(NSSize)newSize
{
  [super setFrameSize:newSize];

  // Re-create the mouse tracking area
  [self destroyMouseTrackingArea];
  [self createMouseTrackingArea];

  // Call OSXWindowImpl::onResize handler
  if ([self window]) {
    OSXWindowImpl* impl = [((OSXWindow*)[self window]) impl];
    if (impl)
      impl->onResize(gfx::Size(newSize.width,
                               newSize.height));
  }
}

- (void)scrollWheel:(NSEvent*)event
{
  Event ev;
  ev.setType(Event::MouseWheel);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setButton(get_mouse_buttons(event));
  ev.setModifiers(get_modifiers_from_nsevent(event));

  int scale = 1;
  if (self.window)
    scale = [(OSXWindow*)self.window scale];

  if (event.hasPreciseScrollingDeltas) {
    ev.setPointerType(she::PointerType::Multitouch);
    ev.setWheelDelta(gfx::Point(-event.scrollingDeltaX / scale,
                                -event.scrollingDeltaY / scale));
    ev.setPreciseWheel(true);
  }
  else {
    // Ignore the acceleration factor, just use the wheel sign.
    gfx::Point pt(0, 0);
    if (event.scrollingDeltaX >= 0.1)
      pt.x = -1;
    else if (event.scrollingDeltaX <= -0.1)
      pt.x = 1;
    if (event.scrollingDeltaY >= 0.1)
      pt.y = -1;
    else if (event.scrollingDeltaY <= -0.1)
      pt.y = 1;

    ev.setPointerType(she::PointerType::Mouse);
    ev.setWheelDelta(pt);
  }

  queue_event(ev);
}

- (void)magnifyWithEvent:(NSEvent*)event
{
  Event ev;
  ev.setType(Event::TouchMagnify);
  ev.setMagnification(event.magnification);
  ev.setPosition(get_local_mouse_pos(self, event));
  ev.setModifiers(get_modifiers_from_nsevent(event));
  ev.setPointerType(she::PointerType::Multitouch);
  queue_event(ev);
}

- (void)tabletProximity:(NSEvent*)event
{
  if (event.isEnteringProximity == YES) {
    switch (event.pointingDeviceType) {
      case NSPenPointingDevice: m_pointerType = she::PointerType::Pen; break;
      case NSCursorPointingDevice: m_pointerType = she::PointerType::Cursor; break;
      case NSEraserPointingDevice: m_pointerType = she::PointerType::Eraser; break;
      default:
        m_pointerType = she::PointerType::Unknown;
        break;
    }
  }
  else {
    m_pointerType = she::PointerType::Unknown;
  }
}

- (void)cursorUpdate:(NSEvent*)event
{
  [self updateCurrentCursor];
}

- (void)setCursor:(NSCursor*)cursor
{
  m_nsCursor = cursor;
  [self updateCurrentCursor];
}

- (void)createMouseTrackingArea
{
  // Create a tracking area to receive mouseMoved events
  m_trackingArea =
    [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited |
                      NSTrackingMouseMoved |
                      NSTrackingActiveAlways |
                      NSTrackingEnabledDuringMouseDrag)
               owner:self
            userInfo:nil];
  [self addTrackingArea:m_trackingArea];
}

- (void)destroyMouseTrackingArea
{
  [self removeTrackingArea:m_trackingArea];
  m_trackingArea = nil;
}

- (void)updateCurrentCursor
{
  if (m_nsCursor) {
    if (!m_visibleMouse) {
      m_visibleMouse = true;
      [NSCursor unhide];
    }
    [m_nsCursor set];
  }
  else if (m_visibleMouse) {
    m_visibleMouse = false;
    [NSCursor hide];
  }
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
  return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  NSPasteboard* pasteboard = [sender draggingPasteboard];

  if ([pasteboard.types containsObject:NSFilenamesPboardType]) {
    NSArray* filenames = [pasteboard propertyListForType:NSFilenamesPboardType];
    generate_drop_files_from_nsarray(filenames);
    return YES;
  }
  else
    return NO;
}

- (void)doCommandBySelector:(SEL)selector
{
  // Do nothing (avoid beep pressing Escape key)
}

- (void)setTranslateDeadKeys:(BOOL)state
{
  g_translateDeadKeys = (state ? true: false);
  g_lastDeadKeyState = 0;
}

@end
