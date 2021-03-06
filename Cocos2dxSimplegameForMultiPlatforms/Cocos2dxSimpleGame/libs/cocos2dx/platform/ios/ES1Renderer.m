
#import "ES1Renderer.h"
#import "OpenGL_Internal.h"
@implementation ES1Renderer

@synthesize context=context_;

- (id) initWithDepthFormat:(unsigned int)depthFormat withPixelFormat:(unsigned int)pixelFormat withSharegroup:(EAGLSharegroup*)sharegroup withMultiSampling:(BOOL) multiSampling withNumberOfSamples:(unsigned int) requestedSamples
{
    if ((self = [super init]))
    {
		if ( sharegroup == nil )
		{
			context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
		}
		else
		{
			context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1 sharegroup:sharegroup];
		}

        if (!context_ || ![EAGLContext setCurrentContext:context_])
        {
            [self release];
            return nil;
        }

        // Create default framebuffer object. The backing will be allocated for the current layer in -resizeFromLayer
        glGenFramebuffersOES(1, &defaultFramebuffer_);
		NSAssert( defaultFramebuffer_, @"Can't create default frame buffer");
        glGenRenderbuffersOES(1, &colorRenderbuffer_);
		NSAssert( colorRenderbuffer_, @"Can't create default render buffer");

        glBindFramebufferOES(GL_FRAMEBUFFER_OES, defaultFramebuffer_);
        glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer_);
        glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, colorRenderbuffer_);

		depthFormat_ = depthFormat;
		
		if( depthFormat_ ) {
//			glGenRenderbuffersOES(1, &depthBuffer_);
//			glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthBuffer_);
//			glRenderbufferStorageOES(GL_RENDERBUFFER_OES, depthFormat_, 100, 100);
//			glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthBuffer_);

			// default buffer
//			glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer_);
		}
		
		pixelFormat_ = pixelFormat;
		multiSampling_ = multiSampling;	
		if (multiSampling_)
		{
			GLint maxSamplesAllowed;
			glGetIntegerv(GL_MAX_SAMPLES_APPLE, &maxSamplesAllowed);
			samplesToUse_ = MIN(maxSamplesAllowed,requestedSamples);
			
			/* Create the MSAA framebuffer (offscreen) */
			glGenFramebuffersOES(1, &msaaFramebuffer_);
			glBindFramebufferOES(GL_FRAMEBUFFER_OES, msaaFramebuffer_);
			
		}

		CHECK_GL_ERROR();
    }

    return self;
}

- (BOOL)resizeFromLayer:(CAEAGLLayer *)layer
{	
    // Allocate color buffer backing based on the current layer size

    glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer_);

	if (![context_ renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:layer])
	{
		/*CCLOG(@"failed to call context");	*/
	}

    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth_);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight_);

	/*CCLOG(@"cocos2d: surface size: %dx%d", (int)backingWidth_, (int)backingHeight_);*/

	if (multiSampling_)
	{
		/* Create the offscreen MSAA color buffer.
		 After rendering, the contents of this will be blitted into ColorRenderbuffer */
		
		//msaaFrameBuffer needs to be binded
		glBindFramebufferOES(GL_FRAMEBUFFER_OES, msaaFramebuffer_);
		glGenRenderbuffersOES(1, &msaaColorbuffer_);
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, msaaColorbuffer_);
		glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER_OES, samplesToUse_,pixelFormat_ , backingWidth_, backingHeight_);
		glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, msaaColorbuffer_);

		if (glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES)
		{
			/*CCLOG(@"Failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));*/
			return NO;
		}
	}
	
	if (depthFormat_) 
	{
		if( ! depthBuffer_ )
			glGenRenderbuffersOES(1, &depthBuffer_);
		
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthBuffer_);
		if( multiSampling_ )
			glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER_OES, samplesToUse_, depthFormat_,backingWidth_, backingHeight_);
		else
			glRenderbufferStorageOES(GL_RENDERBUFFER_OES, depthFormat_, backingWidth_, backingHeight_);
		glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthBuffer_);
		
		// bind color buffer
		glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderbuffer_);
	}
	
	glBindFramebufferOES(GL_FRAMEBUFFER_OES, defaultFramebuffer_);
	
	if (glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES)
	{
		/*CCLOG(@"Failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));*/
		return NO;
	}

	CHECK_GL_ERROR();

    return YES;
}

-(CGSize) backingSize
{
	return CGSizeMake( backingWidth_, backingHeight_);
}

- (NSString*) description
{
	return [NSString stringWithFormat:@"<%@ = %08X | size = %ix%i>", [self class], self, backingWidth_, backingHeight_];
}


- (void)dealloc
{
	/*CCLOGINFO(@"cocos2d: deallocing %@", self);*/

    // Tear down GL
    if(defaultFramebuffer_)
    {
        glDeleteFramebuffersOES(1, &defaultFramebuffer_);
        defaultFramebuffer_ = 0;
    }

    if(colorRenderbuffer_)
    {
        glDeleteRenderbuffersOES(1, &colorRenderbuffer_);
        colorRenderbuffer_ = 0;
    }

	if( depthBuffer_ )
	{
		glDeleteRenderbuffersOES(1, &depthBuffer_);
		depthBuffer_ = 0;
	}

	if ( msaaColorbuffer_)
	{
		glDeleteRenderbuffersOES(1, &msaaColorbuffer_);
		msaaColorbuffer_ = 0;
	}
	
	if ( msaaFramebuffer_)
	{
		glDeleteRenderbuffersOES(1, &msaaFramebuffer_);
		msaaFramebuffer_ = 0;
	}
	
    // Tear down context
    if ([EAGLContext currentContext] == context_)
        [EAGLContext setCurrentContext:nil];

    [context_ release];
    context_ = nil;

    [super dealloc];
}

- (unsigned int) colorRenderBuffer
{
	return colorRenderbuffer_;
}

- (unsigned int) defaultFrameBuffer
{
	return defaultFramebuffer_;
}

- (unsigned int) msaaFrameBuffer
{
	return msaaFramebuffer_;	
}

- (unsigned int) msaaColorBuffer
{
	return msaaColorbuffer_;	
}

@end