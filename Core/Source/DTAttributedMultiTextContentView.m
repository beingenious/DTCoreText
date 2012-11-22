//
//  TextView.m
//  CoreTextExtensions
//
//  Created by Oliver Drobnik on 1/9/11.
//  Copyright 2011 Drobnik.com. All rights reserved.
//

#import "DTAttributedMultiTextContentView.h"
#import "DTCoreText.h"
#import <QuartzCore/QuartzCore.h>

#if !__has_feature(objc_arc)
#error THIS CODE MUST BE COMPILED WITH ARC ENABLED!
#endif

// Commented code useful to find deadlocks
#define SYNCHRONIZE_START(lock) /* NSLog(@"LOCK: FUNC=%s Line=%d", __func__, __LINE__), */dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define SYNCHRONIZE_END(lock) dispatch_semaphore_signal(lock) /*, NSLog(@"UN-LOCK")*/;

@interface DTAttributedMultiTextContentView ()
{
	BOOL _drawDebugFrames;
	DTCoreTextLayouter *_layouter;
	
	CGPoint _layoutOffset;
    CGSize _backgroundOffset;
	
	// lookup bitmask what delegate methods are implemented
	struct 
	{
		unsigned int delegateSupportsCustomViewsForAttachments:1;
		unsigned int delegateSupportsCustomViewsForLinks:1;
		unsigned int delegateSupportsGenericCustomViews:1;
		unsigned int delegateSupportsNotificationAfterDrawing:1;
		unsigned int delegateSupportsNotificationBeforeTextBoxDrawing:1;
	} _delegateFlags;
	
	__unsafe_unretained id <DTAttributedMultiTextContentViewDelegate> _delegate;
}

@end

static Class _layerClassToUseForDTAttributedMultiTextContentView = nil;

@implementation DTAttributedMultiTextContentView (Tiling)

+ (void)setLayerClass:(Class)layerClass
{
	_layerClassToUseForDTAttributedMultiTextContentView = layerClass;
}

+ (Class)layerClass
{
	if (_layerClassToUseForDTAttributedMultiTextContentView)
	{
		return _layerClassToUseForDTAttributedMultiTextContentView;
	}
	
	return [CALayer class];
}

@end


@implementation DTAttributedMultiTextContentView
@synthesize selfLock;

- (void)setup
{
	self.contentMode = UIViewContentModeTopLeft; // to avoid bitmap scaling effect on resize
	// possibly already set in NIB
	if (!self.backgroundColor)
	{
		self.backgroundColor = [DTColor colorWithWhite:1.0 alpha:0.0];
	}
	[self selfLock];
}

- (id)initWithFrame:(CGRect)frame 
{
	self.columnCount = 2;
	self.columnGap = 20;
	if ((self = [super initWithFrame:frame])) 
	{
		[self setup];
	}
	return self;
}

- (id)initWithAttributedString:(NSAttributedString *)attributedString width:(CGFloat)width height:(CGFloat)height
{
	self = [self initWithFrame:CGRectMake(0, 0, width, height)];
	
	if (self)
	{		
		// causes appropriate sizing
		self.attributedString = attributedString;
		[self sizeToFit];
	}
	
	return self;
}

- (void)awakeFromNib
{
	[self setup];
}

- (void)dealloc 
{
	dispatch_release(selfLock);
}

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)ctx
{
	// needs clearing of background
	CGRect rect = CGContextGetClipBoundingBox(ctx);
	
	if (_backgroundOffset.height || _backgroundOffset.width)
	{
		CGContextSetPatternPhase(ctx, _backgroundOffset);
	}
	
	CGContextSetFillColorWithColor(ctx, [self.backgroundColor CGColor]);
	CGContextFillRect(ctx, rect);
	
	// offset layout if necessary
	if (!CGPointEqualToPoint(_layoutOffset, CGPointZero))
	{
		CGAffineTransform transform = CGAffineTransformMakeTranslation(_layoutOffset.x, _layoutOffset.y);
		CGContextConcatCTM(ctx, transform);
	}
	
	NSMutableArray *theLayoutFrames = self.layoutFrames;
	
	// need to prevent updating of string and drawing at the same time
	SYNCHRONIZE_START(selfLock)
	{
		for (DTCoreTextLayoutFrame *lframe in theLayoutFrames) {
			[lframe drawInContext:ctx drawImages:NO drawLinks:NO];
			
			if (_delegateFlags.delegateSupportsNotificationAfterDrawing)
			{
				[_delegate attributedTextContentView:self didDrawLayoutFrame:lframe inContext:ctx];
			}
		}
	}
	SYNCHRONIZE_END(selfLock)
}

- (void)drawRect:(CGRect)rect
{
	CGContextRef context = UIGraphicsGetCurrentContext();
	for (DTCoreTextLayoutFrame *lframe in self.layoutFrames) {
		[lframe drawInContext:context drawImages:NO drawLinks:NO];
	}
}

- (CGSize)attributedStringSizeThatFits:(CGFloat)width
{
	if (!isnormal(width))
	{
		width = self.bounds.size.width;
	}
	
	// attributedStringSizeThatFits: returns an unreliable measure prior to 4.2 for very long documents.
	CGSize neededSize = [self.layouter suggestedFrameSizeToFitEntireStringConstraintedToWidth:width-_edgeInsets.left-_edgeInsets.right];
	return neededSize;
}

- (void)relayoutText
{
    // Make sure we actually have a superview before attempting to relayout the text.
    if (self.superview) {
        // need new layouter
        self.layouter = nil;
        self.layoutFrames = nil;
        
        if (_attributedString)
        {
            // triggers new layout
            CGSize neededSize = [self sizeThatFits:self.bounds.size];
            
            // set frame to fit text preserving origin
            // call super to avoid endless loop
            [self willChangeValueForKey:@"frame"];
            super.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, neededSize.width, neededSize.height);
            [self didChangeValueForKey:@"frame"];
        }
        
        [self setNeedsDisplay];
        [self setNeedsLayout];
    }
}

#pragma mark Properties
- (void)setEdgeInsets:(UIEdgeInsets)edgeInsets
{
	if (!UIEdgeInsetsEqualToEdgeInsets(edgeInsets, _edgeInsets))
	{
		_edgeInsets = edgeInsets;
		
		[self relayoutText];
	}
}

- (void)setAttributedString:(NSAttributedString *)string
{
	if (_attributedString != string)
	{
		_attributedString = [string copy];
	}
}

- (void)setFrame:(CGRect)frame //relayoutText:(BOOL)relayoutText
{
	CGRect oldFrame = self.frame;
	
	[super setFrame:frame];
	
	if (!_layoutFrames)
	{
		return;	
	}
	
	BOOL frameDidChange = !CGRectEqualToRect(oldFrame, frame);
	
	// having a layouter means we are responsible for layouting yourselves
	if (frameDidChange)
	{
		[self relayoutText];
	}
}

//- (void)setFrame:(CGRect)frame
//{
//	// sizeToFit also calls this, but we want to be able to avoid relayouting
//	[self setFrame:frame relayoutText:_relayoutTextOnFrameChange];
//}

- (void)setDrawDebugFrames:(BOOL)drawDebugFrames
{
	if (_drawDebugFrames != drawDebugFrames)
	{
		_drawDebugFrames = drawDebugFrames;
		
		[self setNeedsDisplay];
	}
}

- (void)setBackgroundColor:(DTColor *)newColor
{
	super.backgroundColor = newColor;
	
	if ([newColor alphaComponent]<1.0)
	{
		self.opaque = NO;
	}
	else 
	{
		self.opaque = YES;
	}
}


- (DTCoreTextLayouter *)layouter
{
	SYNCHRONIZE_START(selfLock)
	{
		if (!_layouter)
		{
			if (_attributedString)
			{
				_layouter = [[DTCoreTextLayouter alloc] initWithAttributedString:_attributedString];
			}
		}
	}
	SYNCHRONIZE_END(selfLock)
	
	return _layouter;
}

- (void)setLayouter:(DTCoreTextLayouter *)layouter
{
	SYNCHRONIZE_START(selfLock)
	{
		if (_layouter != layouter)
		{
			_layouter = layouter;
		}
	}
	SYNCHRONIZE_END(selfLock)
}

- (NSMutableArray *)layoutFrames
{
	DTCoreTextLayouter *theLayouter = self.layouter;
	
	if (!_layoutFrames)
	{
		// prevent unnecessary locking if we don't need to create new layout frame
		SYNCHRONIZE_START(selfLock)
		{
			// Test again - small window where another thread could have been setting this value
			if (!_layoutFrames)
			{
				// we can only layout if we have our own layouter
				if (theLayouter)
				{
					_layoutFrames = [[NSMutableArray alloc] init];
					CGRect rect = UIEdgeInsetsInsetRect(self.bounds, _edgeInsets);
					NSInteger offset = 0;
					NSInteger columnWidth = (rect.size.width - (self.columnGap * (self.columnCount - 1))) / self.columnCount;
					for (NSInteger i = 0; i < self.columnCount; i++) {
						DTCoreTextLayoutFrame* lframe = [theLayouter layoutFrameWithRect:CGRectMake(((columnWidth + self.columnGap) * i), 0, columnWidth, rect.size.height) range:NSMakeRange(offset, 0)];
						if (lframe) {
							[_layoutFrames addObject:lframe];
							offset = [lframe visibleStringRange].length + [lframe visibleStringRange].location;
                            float globalLineHeight = 0;
                            for (DTCoreTextLayoutLine *line in lframe.lines)
                                globalLineHeight += line.frame.size.height;
                            globalLineHeight /= [lframe.lines count];
                            _averageLineHeight = (_averageLineHeight) ? (globalLineHeight + _averageLineHeight) / 2 : globalLineHeight;
						}
					}
				}
			}
		}
		SYNCHRONIZE_END(selfLock)
	}
	
	return _layoutFrames;
}

- (void)setDelegate:(id<DTAttributedMultiTextContentViewDelegate>)delegate
{
	_delegate = delegate;
	
	_delegateFlags.delegateSupportsCustomViewsForAttachments = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForAttachment:frame:)];
	_delegateFlags.delegateSupportsCustomViewsForLinks = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForLink:identifier:frame:)];
	_delegateFlags.delegateSupportsGenericCustomViews = [_delegate respondsToSelector:@selector(attributedTextContentView:viewForAttributedString:frame:)];
	_delegateFlags.delegateSupportsNotificationAfterDrawing = [_delegate respondsToSelector:@selector(attributedTextContentView:didDrawLayoutFrame:inContext:)];
	_delegateFlags.delegateSupportsNotificationBeforeTextBoxDrawing = [_delegate respondsToSelector:@selector(attributedTextContentView:shouldDrawBackgroundForTextBlock:frame:context:forLayoutFrame:)];
}


- (dispatch_semaphore_t)selfLock
{
	if (!selfLock)
	{
		selfLock = dispatch_semaphore_create(1);
	}
	
	return selfLock;
}

@synthesize columnCount = _columnCount;
@synthesize columnGap = _columnGap;
@synthesize layouter = _layouter;
@synthesize layoutFrames = _layoutFrames;
@synthesize attributedString = _attributedString;
@synthesize delegate = _delegate;
@synthesize edgeInsets = _edgeInsets;
@synthesize drawDebugFrames = _drawDebugFrames;
@synthesize layoutOffset = _layoutOffset;
@synthesize backgroundOffset = _backgroundOffset;
@synthesize averageLineHeight = _averageLineHeight;

@end
