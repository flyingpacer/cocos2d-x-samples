/****************************************************************************
Copyright (c) 2010 cocos2d-x.org

http://www.cocos2d-x.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
****************************************************************************/

#include "CCDirector.h"
#include "CCScene.h"
#include "NSMutableArray.h"
#include "CCScheduler.h"
#include "ccMacros.h"
#include "CCXCocos2dDefine.h"
#include "CCTouchDispatcher.h"
#include "support/opengl_support/glu.h"
#include "CGPointExtension.h"
#include "CCTransition.h"
#include "CCTextureCache.h"
#include "CCTransition.h"
#include "CCSpriteFrameCache.h"
#include "NSAutoreleasePool.h"
#include "platform/platform.h"
#include "CCXApplication.h"
#include "CCLabelBMFont.h"
#include "CCActionManager.h"
#include "CCLabelTTF.h"
#include "CCConfiguration.h"
#include "CCKeypadDispatcher.h"
#include "CCGL.h"
#include "CCDirectorDisplayLinkMacWrapper.h"

#if CC_ENABLE_PROFILERS
#include "support/CCProfiling.h"
#endif // CC_ENABLE_PROFILERS

#include <string>

using namespace std;
using namespace cocos2d;
namespace  cocos2d 
{

// singleton stuff
static CCDisplayLinkDirector s_sharedDirector;
static bool s_bFirstRun = true;

#define kDefaultFPS		60  // 60 frames per second
extern const char* cocos2dVersion(void);

CCDirector* CCDirector::sharedDirector(void)
{
	if (s_bFirstRun)
	{
		s_sharedDirector.init();
        s_bFirstRun = false;
	}

	return &s_sharedDirector;
}

bool CCDirector::init(void)
{
	CCLOG("cocos2d: %s", cocos2dVersion());

	CCLOG("cocos2d: Using Director Type: CCDirectorDisplayLink");

	// scenes
	m_pRunningScene = NULL;
	m_pNextScene = NULL;

	m_pNotificationNode = NULL;

	m_dOldAnimationInterval = m_dAnimationInterval = 1.0 / kDefaultFPS;	
	m_pobScenesStack = new NSMutableArray<CCScene*>();

	// Set default projection (3D)
	m_eProjection = kCCDirectorProjectionDefault;

	// projection delegate if "Custom" projection is used
	m_pProjectionDelegate = NULL;

	// FPS
	m_bDisplayFPS = false;
	m_nFrames = 0;
	m_pszFPS = new char[10];
	m_pLastUpdate = new struct cc_timeval();

	// paused ?
	m_bPaused = false;

	m_obWinSizeInPixels = m_obWinSizeInPoints = CGSizeZero;	

	m_pobOpenGLView = NULL;

	m_bIsFullScreen = false;
	m_nResizeMode = kCCDirectorResize_AutoScale;

	m_pFullScreenGLView = NULL;
	m_pFullScreenWindow = NULL;
	m_pWindowGLView = NULL;
	m_winOffset = CGPointZero;

	// create autorelease pool
	NSPoolManager::getInstance()->push();

	return true;
}

CCDirector::~CCDirector(void)
{
	CCLOGINFO("cocos2d: deallocing %p", this);

#if CC_DIRECTOR_FAST_FPS
	CCX_SAFE_RELEASE(m_pFPSLabel);
#endif 
    
	CCX_SAFE_RELEASE(m_pRunningScene);
	CCX_SAFE_RELEASE(m_pNotificationNode);
	CCX_SAFE_RELEASE(m_pobScenesStack);

	// pop the autorelease pool
	NSPoolManager::getInstance()->pop();

	// delete m_pLastUpdate
	CCX_SAFE_DELETE(m_pLastUpdate);

	// delete last compute time
	CCX_SAFE_DELETE(m_pLastComputeFrameRate);

    CCKeypadDispatcher::purgeSharedDispatcher();

	// delete fps string
	delete []m_pszFPS;

	[m_pFullScreenGLView release];
	[m_pFullScreenWindow release];
	[m_pWindowGLView release];
	[[CCDirectorDisplayLinkMacWrapper sharedDisplayLinkMacWrapper] release];
}

void CCDirector::setGLDefaultValues(void)
{
	// This method SHOULD be called only after openGLView_ was initialized
	assert(m_pobOpenGLView);

	setAlphaBlending(true);
	setDepthTest(true);
	setProjection(m_eProjection);

	// set other opengl default values
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

#if CC_DIRECTOR_FAST_FPS
	if (! m_pFPSLabel)
	{
        m_pFPSLabel = CCLabelTTF::labelWithString("00.0", "Arial", 24);
		m_pFPSLabel->retain();
	}
#endif
}

// Draw the SCene
void CCDirector::drawScene(void)
{
	// calculate "global" dt
	calculateDeltaTime();

	//tick before glClear: issue #533
	if (! m_bPaused)
	{
		CCScheduler::sharedScheduler()->tick(m_fDeltaTime);
	}

	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    /* to avoid flickr, nextScene MUST be here: after tick and before draw.
	 XXX: Which bug is this one. It seems that it can't be reproduced with v0.9 */
	if (m_pNextScene)
	{
		setNextScene();
	}

	glPushMatrix();

	// By default enable VertexArray, ColorArray, TextureCoordArray and Texture2D
	CC_ENABLE_DEFAULT_GL_STATES();

	// draw the scene
    if (m_pRunningScene)
    {
        m_pRunningScene->visit();
    }

	// draw the notifications node
	if (m_pNotificationNode)
	{
		m_pNotificationNode->visit();
	}

	if (m_bDisplayFPS)
	{
		showFPS();
	}

#if CC_ENABLE_PROFILERS
	showProfilers();
#endif

	CC_DISABLE_DEFAULT_GL_STATES();

	glPopMatrix();

	// swap buffers
	if (m_pobOpenGLView)
    {
        m_pobOpenGLView->swapBuffers();
    }
}

void CCDirector::calculateDeltaTime(void)
{
    struct cc_timeval now;

	if (CCTime::gettimeofdayCocos2d(&now, NULL) != 0)
	{
		CCLOG("error in gettimeofday");
        m_fDeltaTime = 0;
		return;
	}

	// new delta time
	if (m_bNextDeltaTimeZero)
	{
		m_fDeltaTime = 0;
		m_bNextDeltaTimeZero = false;
	}
	else
	{
		m_fDeltaTime = (now.tv_sec - m_pLastUpdate->tv_sec) + (now.tv_usec - m_pLastUpdate->tv_usec) / 1000000.0f;
		m_fDeltaTime = MAX(0, m_fDeltaTime);
	}

	*m_pLastUpdate = now;
}


// m_dAnimationInterval
void CCDirector::setAnimationInterval(double dValue)
{
	CCLOG("cocos2d: Director#setAnimationInterval. Overrride me");
	assert(0);
}


// m_pobOpenGLView

void CCDirector::setOpenGLView(CC_GLVIEW *pobOpenGLView)
{
	assert(pobOpenGLView);

	if (m_pobOpenGLView != pobOpenGLView)
	{
		[m_pobOpenGLView release];
		m_pobOpenGLView = [pobOpenGLView retain];

		

		// set size
		m_obWinSizeInPixels = m_obWinSizeInPoints = NSSizeToCGSize([pobOpenGLView bounds].size);

		setGLDefaultValues();	

		// cache the NSWindow and NSOpgenGLView created from the NIB
		if (!m_bIsFullScreen && !m_pWindowGLView)
		{
			m_pWindowGLView = [pobOpenGLView retain];
			m_originalWinSize = m_obWinSizeInPixels;
		}

		// for DirectorDisplayLink, because the it doesn't override setOpenGLView

		CCEventDispatcher *eventDispatcher = [CCEventDispatcher sharedDispatcher];
		[m_pobOpenGLView setEventDelegate: eventDispatcher];
		[eventDispatcher setDispatchEvents: YES];

		// Enable Touches. Default no.
		[pobOpenGLView setAcceptsTouchEvents:NO];
		// [view setAcceptsTouchEvents:YES];


		// Synchronize buffer swaps with vertical refresh rate
		[[pobOpenGLView openGLContext] makeCurrentContext];
		GLint swapInt = 1;
		[[pobOpenGLView openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval]; 
	}
}

void CCDirector::setNextDeltaTimeZero(bool bNextDeltaTimeZero)
{
	m_bNextDeltaTimeZero = bNextDeltaTimeZero;
}

void CCDirector::setProjection(ccDirectorProjection kProjection)
{
	CGSize size = m_obWinSizeInPixels;

	CGPoint offset = CGPointZero;
	float widthAspect = size.width;
	float heightAspect = size.height;

	if( m_nResizeMode == kCCDirectorResize_AutoScale && ! CGSizeEqualToSize(m_originalWinSize, CGSizeZero ) ) 
	{
		size = m_originalWinSize;

		float aspect = m_originalWinSize.width / m_originalWinSize.height;
		widthAspect = m_obWinSizeInPixels.width;
		heightAspect = m_obWinSizeInPixels.width / aspect;

		if( heightAspect > m_obWinSizeInPixels.height ) 
		{
			widthAspect = m_obWinSizeInPixels.height * aspect;
			heightAspect = m_obWinSizeInPixels.height;			
		}

		m_winOffset.x = (m_obWinSizeInPixels.width - widthAspect) / 2;
		m_winOffset.y =  (m_obWinSizeInPixels.height - heightAspect) / 2;

		offset = m_winOffset;
	}

	switch (kProjection) {
	case kCCDirectorProjection2D:
		glViewport(offset.x, offset.y, widthAspect, heightAspect);
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		ccglOrtho(0, size.width, 0, size.height, -1024, 1024);
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		break;

	case kCCDirectorProjection3D:
		glViewport(offset.x, offset.y, widthAspect, heightAspect);
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		gluPerspective(60, (GLfloat)widthAspect/heightAspect, 0.1f, 1500.0f);

		glMatrixMode(GL_MODELVIEW);	
		glLoadIdentity();

		float eyeZ = size.height * getZEye() / m_obWinSizeInPixels.height;

		gluLookAt( size.width/2, size.height/2, eyeZ,
				size.width/2, size.height/2, 0,
				0.0f, 1.0f, 0.0f);			
		break;

	case kCCDirectorProjectionCustom:
		if(m_pProjectionDelegate)
		{
			m_pProjectionDelegate->updateProjection();
		}
		break;

	default:
		CCLOG("cocos2d: Director: unrecognized projecgtion");
		break;
	}

	m_eProjection = kProjection;
}

void CCDirector::purgeCachedData(void)
{
    CCLabelBMFont::purgeCachedData();
	CCTextureCache::purgeSharedTextureCache();
}

float CCDirector::getZEye(void)
{
    return (m_obWinSizeInPixels.height / 1.1566f);	
}

void CCDirector::setAlphaBlending(bool bOn)
{
	if (bOn)
	{
		glEnable(GL_BLEND);
		glBlendFunc(CC_BLEND_SRC, CC_BLEND_DST);
	}
	else
	{
		glDisable(GL_BLEND);
	}
}

void CCDirector::setDepthTest(bool bOn)
{
	if (bOn)
	{
		ccglClearDepth(1.0f);
		glEnable(GL_DEPTH_TEST);
		glDepthFunc(GL_LEQUAL);
		glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
	}
	else
	{
		glDisable(GL_DEPTH_TEST);
	}
}

CGPoint CCDirector::convertToGL(CGPoint obPoint)
{
	assert(0);
	return CGPointZero;
}

CGPoint CCDirector::convertToUI(CGPoint obPoint)
{
	assert(0);
	return CGPointZero;
}

CGSize CCDirector::getWinSize(void)
{
	if (m_nResizeMode == kCCDirectorResize_AutoScale)
	{
		return m_originalWinSize;
	}

	return m_obWinSizeInPixels;
}

CGSize CCDirector::getWinSizeInPixels()
{
	return getWinSize();
}

// return the current frame size
CGSize CCDirector::getDisplaySizeInPixels(void)
{
	return m_obWinSizeInPixels;
}

void CCDirector::reshapeProjection(CGSize newWindowSize)
{
    m_obWinSizeInPixels = m_originalWinSize = newWindowSize;
	setProjection(m_eProjection);
}

// scene management

void CCDirector::runWithScene(CCScene *pScene)
{
	assert(pScene != NULL);
	assert(m_pRunningScene == NULL);

	pushScene(pScene);
	startAnimation();
}

void CCDirector::replaceScene(CCScene *pScene)
{
	assert(pScene != NULL);

	unsigned int index = m_pobScenesStack->count();

	m_bSendCleanupToScene = true;
	m_pobScenesStack->replaceObjectAtIndex(index - 1, pScene);

	m_pNextScene = pScene;
}

void CCDirector::pushScene(CCScene *pScene)
{
	assert(pScene);

	m_bSendCleanupToScene = false;

	m_pobScenesStack->addObject(pScene);
	m_pNextScene = pScene;
}

void CCDirector::popScene(void)
{
	assert(m_pRunningScene != NULL);

	m_pobScenesStack->removeLastObject();
	unsigned int c = m_pobScenesStack->count();

	if (c == 0)
	{
		end();
	}
	else
	{
		m_bSendCleanupToScene = true;
		m_pNextScene = m_pobScenesStack->getObjectAtIndex(c - 1);
	}
}

void CCDirector::end(void)
{
	// don't release the event handlers
	// They are needed in case the director is run again
	CCTouchDispatcher::sharedDispatcher()->removeAllDelegates();

	m_pRunningScene->onExit();
	m_pRunningScene->cleanup();
	m_pRunningScene->release();

	m_pRunningScene = NULL;
	m_pNextScene = NULL;

	// remove all objects, but don't release it.
	// runWithScene might be executed after 'end'.
	m_pobScenesStack->removeAllObjects();

	stopAnimation();

#if CC_DIRECTOR_FAST_FPS
	CCX_SAFE_RELEASE_NULL(m_pFPSLabel);
#endif

	CCX_SAFE_RELEASE_NULL(m_pProjectionDelegate);

	// purge bitmap cache
	CCLabelBMFont::purgeCachedData();

	// purge all managers
	CCAnimationCache::purgeSharedAnimationCache();
 	CCSpriteFrameCache::purgeSharedSpriteFrameCache();
	CCActionManager::sharedManager()->purgeSharedManager();
	CCScheduler::purgeSharedScheduler();
	CCTextureCache::purgeSharedTextureCache();

	// OpenGL view
	[m_pobOpenGLView release];
	m_pobOpenGLView = NULL;
}

void CCDirector::setNextScene(void)
{
	ccSceneFlag runningSceneType = ccNormalScene;
	ccSceneFlag newSceneType = m_pNextScene->getSceneType();

	if (m_pRunningScene)
	{
		runningSceneType = m_pRunningScene->getSceneType();
	}

	// If it is not a transition, call onExit/cleanup
 	/*if (! newIsTransition)*/
	if (! (newSceneType & ccTransitionScene))
 	{
         if (m_pRunningScene)
         {
             m_pRunningScene->onExit();
         }
 
 		// issue #709. the root node (scene) should receive the cleanup message too
 		// otherwise it might be leaked.
 		if (m_bSendCleanupToScene && m_pRunningScene)
 		{
 			m_pRunningScene->cleanup();
 		}
 	}

    if (m_pRunningScene)
    {
        m_pRunningScene->release();
    }
    m_pRunningScene = m_pNextScene;
	m_pNextScene->retain();
	m_pNextScene = NULL;

	if (! (runningSceneType & ccTransitionScene) && m_pRunningScene)
	{
		m_pRunningScene->onEnter();
		m_pRunningScene->onEnterTransitionDidFinish();
	}
}

void CCDirector::pause(void)
{
	if (m_bPaused)
	{
		return;
	}

	m_dOldAnimationInterval = m_dAnimationInterval;

	// when paused, don't consume CPU
	setAnimationInterval(1 / 4.0);
	m_bPaused = true;
}

void CCDirector::resume(void)
{
	if (! m_bPaused)
	{
		return;
	}

	setAnimationInterval(m_dOldAnimationInterval);

	if (CCTime::gettimeofdayCocos2d(m_pLastUpdate, NULL) != 0)
	{
		CCLOG("cocos2d: Director: Error in gettimeofday");
	}

	m_bPaused = false;
	m_fDeltaTime = 0;
}

void CCDirector::startAnimation(void)
{
	CCLOG("cocos2d: Director#startAnimation. Overrride me");
	assert(0);
}

void CCDirector::stopAnimation(void)
{
	CCLOG("cocos2d: Director#stopAnimation. Overrride me");
	assert(0);
}

void CCDirector::mainLoop(void)
{
    CCLOG("cocos2d: Director#preMainLoop. Overrride me");
	assert(0);
}

#if CC_DIRECTOR_FAST_FPS
// display the FPS using a LabelAtlas
// updates the FPS every frame
void CCDirector::showFPS(void)
{
	m_nFrames++;
	m_fAccumDt += m_fDeltaTime;

	if (m_fAccumDt > CC_DIRECTOR_FPS_INTERVAL)
	{
		m_fFrameRate = m_nFrames / m_fAccumDt;
		m_nFrames = 0;
		m_fAccumDt = 0;

		sprintf(m_pszFPS, "%.1f", m_fFrameRate);
		m_pFPSLabel->setString(m_pszFPS);
	}

    m_pFPSLabel->draw();
}
#endif // CC_DIRECTOR_FAST_FPS

void CCDirector::showProfilers()
{
#if CC_ENABLE_PROFILERS
	m_fAccumDtForProfiler += m_fDeltaTime;
	if (m_fAccumDtForProfiler > 1.0f)
	{
		m_fAccumDtForProfiler = 0;
		CCProfiler::sharedProfiler()->displayTimers();
	}
#endif
}

/***************************************************
* mobile platforms specific functions
**************************************************/

// is the view currently attached
bool CCDirector::isOpenGLAttached(void)
{
	assert(false);
	return false;
}

void CCDirector::updateContentScaleFactor()
{
	assert(0);
}

// detach or attach to a view or a window
bool CCDirector::detach(void)
{
	assert(false);
	return false;
}

void CCDirector::setDepthBufferFormat(tDepthBufferFormat kDepthBufferFormat)
{
	assert(false);
}

void CCDirector::setPixelFormat(tPixelFormat kPixelFormat)
{
	assert(false);
}

tPixelFormat CCDirector::getPiexFormat(void)
{
	assert(false);
	return m_ePixelFormat;
}

bool CCDirector::setDirectorType(ccDirectorType obDirectorType)
{
	// we only support CCDisplayLinkDirector
	CCDirector::sharedDirector();

	return true;
}

bool CCDirector::enableRetinaDisplay(bool enabled)
{
	assert(false);
	return false;
}

CGFloat CCDirector::getContentScaleFactor(void)
{
	assert(false);
	return m_fContentScaleFactor;
}

void CCDirector::setContentScaleFactor(CGFloat scaleFactor)
{
	assert(false);
}

void CCDirector::applyOrientation(void)
{
	assert(false);
}

ccDeviceOrientation CCDirector::getDeviceOrientation(void)
{
	assert(false);
	return m_eDeviceOrientation;
}

void CCDirector::setDeviceOrientation(ccDeviceOrientation kDeviceOrientation)
{
	assert(false);
}

/***************************************************
* PC platforms specific functions, such as mac
**************************************************/

CGPoint CCDirector::convertEventToGL(NSEvent *event);
{
    ///@todo NSEvent have not implemented
	return CGPointZero;
}

bool CCDirector::isFullScreen(void)
{
    return m_bIsFullScreen;
}

void CCDirector::setResizeMode(int resizeMode)
{
    assert("not supported.");
}

int CCDirector::getResizeMode(void);
{
    assert("not supported.");
	return -1;
}

void CCDirector::setFullScreen(bool fullscreen)
{
	// Mac OS X 10.6 and later offer a simplified mechanism to create full-screen contexts
#if MAC_OS_X_VERSION_MIN_REQUIRED > MAC_OS_X_VERSION_10_5

	if( m_bIsFullScreen != fullscreen ) 
	{
		m_bIsFullScreen = fullscreen;

		if( fullscreen ) 
		{
			// create the fullscreen view/window
			NSRect mainDisplayRect, viewRect;

			// Create a screen-sized window on the display you want to take over
			// Note, mainDisplayRect has a non-zero origin if the key window is on a secondary display
			mainDisplayRect = [[NSScreen mainScreen] frame];
			m_pFullScreenWindow = [[NSWindow alloc] initWithContentRect:mainDisplayRect
                                                    styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                    defer:YES];

			// Set the window level to be above the menu bar
			[m_pFullScreenWindow setLevel:NSMainMenuWindowLevel+1];

			// Perform any other window configuration you desire
			[m_pFullScreenWindow setOpaque:YES];
			[m_pFullScreenWindow setHidesOnDeactivate:YES];

			// Create a view with a double-buffered OpenGL context and attach it to the window
			// By specifying the non-fullscreen context as the shareContext, we automatically inherit the OpenGL objects (textures, etc) it has defined
			viewRect = NSMakeRect(0.0, 0.0, mainDisplayRect.size.width, mainDisplayRect.size.height);

			m_pFullScreenGLView = [[MacGLView alloc] initWithFrame:viewRect shareContext:[m_pobOpenGLView openGLContext]];

			[m_pFullScreenWindow setContentView:m_pFullScreenGLView];

			// Show the window
			[m_pFullScreenWindow makeKeyAndOrderFront:self];

			[self setOpenGLView:fullScreenGLView_];

		} 
		else 
		{
			[m_pFullScreenWindow release];
			[m_pFullScreenGLView release];
			m_pFullScreenWindow = nil;
			m_pFullScreenGLView = nil;

			[[m_pFullScreenGLView openGLContext] makeCurrentContext];
			setOpenGLView(m_pFullScreenGLView);
		}

		[m_pobOpenGLView setNeedsDisplay:YES];
	}
#else
#error Full screen is not supported for Mac OS 10.5 or older yet
#error If you don't want FullScreen support, you can safely remove these 2 lines
#endif
}

CGPoint CCDirector::convertToLogicalCoordinates(CGPoint coordinates)
{
	CGPoint ret;

	if( m_nResizeMode == kCCDirectorResize_NoScale )
	{
		ret = coordinates;
	}
	else 
	{
		float x_diff = m_originalWinSize.width / (m_obWinSizeInPixels.width - m_winOffset.x * 2);
		float y_diff = m_originalWinSize.height / (m_obWinSizeInPixels.height - m_winOffset.y * 2);

		float adjust_x = (m_obWinSizeInPixels.width * x_diff - m_originalWinSize.width ) / 2;
		float adjust_y = (m_obWinSizeInPixels.height * y_diff - m_originalWinSize.height ) / 2;

		ret = CGPointMake( (x_diff * coordinates.x) - adjust_x, ( y_diff * coordinates.y ) - adjust_y );		
	}

	return ret;
}


/***************************************************
* implementation of DisplayLinkDirector
**************************************************/

// should we afford 4 types of director ??
// I think DisplayLinkDirector is enough
// so we now only support DisplayLinkDirector
void CCDisplayLinkDirector::startAnimation(void)
{
	if (CCTime::gettimeofdayCocos2d(m_pLastUpdate, NULL) != 0)
	{
		CCLOG("cocos2d: DisplayLinkDirector: Error on gettimeofday");
	}

	m_bInvalid = false;

	[[CCDirectorDisplayLinkMacWrapper sharedDisplayLinkMacWrapper] startAnimation];
}

void CCDisplayLinkDirector::mainLoop(void)
{
 	if (! m_bInvalid)
 	{
 		drawScene();
	 
 		// release the objects
 		NSPoolManager::getInstance()->pop();		
 	}
}

void CCDisplayLinkDirector::stopAnimation(void)
{
	m_bInvalid = true;

    [[CCDirectorDisplayLinkMacWrapper sharedDisplayLinkMacWrapper] stopAnimation];
}

void CCDisplayLinkDirector::setAnimationInterval(double dValue)
{
	m_dAnimationInterval = dValue;
	m_fExpectedFrameRate = (ccTime)(1 / m_dAnimationInterval);
	if (! m_bInvalid)
	{
		stopAnimation();
		startAnimation();
	}	
}

} //namespace   cocos2d 
