#include <sstream>
#include <cmath>
#include "vim.h"

#import <Cocoa/Cocoa.h>

#import "view.h"
#import "redraw.h"
#import "input.h"
#import "keys.h"

@implementation VimView (Input)

- (void)keyDown:(NSEvent *)event
{
    NSTextInputContext *con = [NSTextInputContext currentInputContext];
    [NSCursor setHiddenUntilMouseMoves:YES];

    /* When a deadkey is received the character length is 0. Allow
       NSTextInputContext to handle the key press only if Macmeta is
       not turned on */
    if ([self hasMarkedText]) {
        [con handleEvent:event];
    } else if (!mOptAsMeta && ([[event characters] length] == 0)) {
        [con handleEvent:event];
    } else {
        std::stringstream raw;
        translateKeyEvent(raw, event, mOptAsMeta);
        std::string raws = raw.str();

        if (raws.size())
            [self vimInput:raws];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSEventType type = [event type];
    unsigned flags = [event modifierFlags];

    /* <C-Tab> & <C-S-Tab> do not trigger keyDown events.
       Catch the key event here and pass it to keyDown. */
    if (NSKeyDown == type && NSControlKeyMask & flags && 48 == [event keyCode]) {
        [self keyDown:event];
        return YES;
    }
   
    return NO;
}

- (void)mouseEvent:(NSEvent *)event drag:(BOOL)drag type:(const char *)type
{
    NSPoint cellLoc = [self cellContainingEvent:event];

    /* Only send drag events when we cross cell boundaries */
    if (drag) {
        static NSPoint lastCellLoc = CGPointMake(-1, -1);
        if (CGPointEqualToPoint(lastCellLoc, cellLoc))
            return;
        lastCellLoc = cellLoc;
    }

    int mods = [event modifierFlags];

    /* Add modifier flags and mouse position */
    std::stringstream ss;
    addModifiedName(ss, event, type);

    ss << "<" << cellLoc.x << "," << cellLoc.y << ">";

    [self vimInput:ss.str()];
}

- (void)mouseDown:    (NSEvent *)event { [self mouseEvent:event drag:NO type:"LeftMouse"]; }
- (void)mouseDragged: (NSEvent *)event { [self mouseEvent:event drag:YES type:"LeftDrag"]; }
- (void)mouseUp:      (NSEvent *)event { [self mouseEvent:event drag:NO type:"LeftRelease"]; }

- (void)rightMouseDown:    (NSEvent *)event { [self mouseEvent:event drag:NO type:"RightMouse"]; }
- (void)rightMouseDragged: (NSEvent *)event { [self mouseEvent:event drag:YES type:"RightDrag"]; }
- (void)rightMouseUp:      (NSEvent *)event { [self mouseEvent:event drag:NO type:"RightRelease"]; }

- (void)otherMouseDown:    (NSEvent *)event { [self mouseEvent:event drag:NO type:"MiddleMouse"]; }
- (void)otherMouseDragged: (NSEvent *)event { [self mouseEvent:event drag:YES type:"MiddleDrag"]; }
- (void)otherMouseUp:      (NSEvent *)event { [self mouseEvent:event drag:NO type:"MiddleRelease"]; }

- (void)scrollWheel:(NSEvent *)event
{
    CGFloat x = [event deltaX], y = [event deltaY];

    if ([event phase] == NSEventPhaseBegan) {
        mScrollDelta = 0;
        mScrollIsHorizontal = std::abs(x) > std::abs(y);
    }
    
    if (mScrollIsHorizontal) 
        mScrollDelta += x;
    else
        mScrollDelta += y;
  
    CGFloat minDistance = mScrollIsHorizontal ? mCharSize.width : mCharSize.height;
    
    // TODO: Scrolling is scaled by 10. This value makes scrolling feel good,
    // but I have no idea what the ideal value would be. Maybe this should be
    // tunable? -sfuller
    minDistance *= 0.1f;

    const char* positiveScrollCommand;
    const char* negativeScrollCommand;

    if (mScrollIsHorizontal) {
        positiveScrollCommand = "ScrollWheelLeft";
        negativeScrollCommand = "ScrollWheelRight";
    } else {
        positiveScrollCommand = "ScrollWheelUp";
        negativeScrollCommand = "ScrollWheelDown";
    }
    
    for (;;) {
        const char *type;
        if (mScrollDelta > minDistance) {
            type = positiveScrollCommand;
            mScrollDelta -= minDistance;
        }
        else if(mScrollDelta < 0) {
            type = negativeScrollCommand;
            mScrollDelta += minDistance;
        }
        else {
            break;
        }

        NSPoint cellLoc = [self cellContainingEvent:event];

        std::stringstream ss;
        addModifiedName(ss, event, type);

        ss << "<" << cellLoc.x << "," << cellLoc.y << ">";
        [self vimInput:ss.str()];
    }
}

/* Send an input string to Vim. */
- (void)vimInput:(const std::string &)input
{
    if (mInsertMode)
        [[self window] setDocumentEdited:YES];

    mVim->vim_input(input);
}

- (NSPoint)cellContainingEvent:(NSEvent *)event
{
    NSPoint winLoc = [event locationInWindow];
    NSPoint viewLoc = [self convertPoint:winLoc fromView:nil];
    NSPoint cellLoc = [self cellContaining:viewLoc];
    return cellLoc;
}

/* -- NSTextInputClient methods -- */

- (BOOL)hasMarkedText { return mMarkedText.length? YES : NO; }
- (NSRange)markedRange { NSLog(@"MR"); return {NSNotFound, 0}; }
- (NSRange)selectedRange { NSLog(@"SR"); return {NSNotFound, 0}; }

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)x
        replacementRange:(NSRange)y
{
    if (!mMarkedText)
        mMarkedText = [@"" retain];

    if ([string isKindOfClass:[NSAttributedString class]])
        string = [string string];

    [mMarkedText autorelease];
    mMarkedText = [mMarkedText stringByAppendingString:string];
    [mMarkedText retain];

    /* Draw the fake character on the screen as if
       nvim would've told it to do so */
    typedef std::tuple<std::string, std::vector<std::string>> putmsg_t;
    typedef std::tuple<std::string, std::vector<int>> cursormsg_t;

    putmsg_t putdata("put", {[string UTF8String]});
    cursormsg_t cursordata("cursor_goto",
            {(int)mCursorDisplayPos.y, (int)mCursorDisplayPos.x});

    msgpack::sbuffer sbuf;
    msgpack::packer<msgpack::sbuffer> pk(sbuf);
    pk.pack_array(2);
    pk.pack(putdata);
    pk.pack(cursordata);

    msgpack::unpacked msg;
    msgpack::unpack(msg, sbuf.data(), sbuf.size());
    msgpack::object obj = msg.get();

    [self redraw:obj];
}

- (void)unmarkText
{
    [mMarkedText release];
    mMarkedText = nil;
}

- (NSArray *)validAttributesForMarkedText
{
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)aRange
                                                actualRange:(NSRangePointer)actualRange
{
    return nil;
}

- (void)insertText:(id)string
  replacementRange:(NSRange)replacementRange
{
    if ([string isKindOfClass:[NSAttributedString class]])
        string = [string string];

    [self unmarkText];
    [self insertText:string];
}

- (void)insertText:(NSString *)string
{
    string = [string stringByReplacingOccurrencesOfString:@"<"
                                               withString:@"<lt>"];

    [self vimInput:[string UTF8String]];
}


- (NSUInteger)characterIndexForPoint:(NSPoint)aPoint
{
    return NSNotFound;
}

- (NSRect)firstRectForCharacterRange:(NSRange)aRange
                         actualRange:(NSRangePointer)actualRange
{
    return {{0,0},{0,0}};
}

- (void)doCommandBySelector:(SEL)selector
{
}

@end
