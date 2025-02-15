/*
This file is part of Telegram Desktop,
the official desktop application for the Telegram messaging service.

For license and copyright information please follow this link:
https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL
*/
#include "platform/mac/main_window_mac.h"

#include "styles/style_window.h"
#include "mainwindow.h"
#include "mainwidget.h"
#include "core/application.h"
#include "auth_session.h"
#include "history/history.h"
#include "history/history_widget.h"
#include "history/history_inner_widget.h"
#include "storage/localstorage.h"
#include "window/notifications_manager_default.h"
#include "window/themes/window_theme.h"
#include "platform/platform_notifications_manager.h"
#include "platform/platform_info.h"
#include "boxes/peer_list_controllers.h"
#include "boxes/about_box.h"
#include "lang/lang_keys.h"
#include "platform/mac/mac_utilities.h"

#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CFURL.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/ev_keymap.h>
#include <SPMediaKeyTap.h>

#include "media/player/media_player_instance.h"
#include "media/audio/media_audio.h"
#include "platform/mac/mac_touchbar.h"
#include "data/data_session.h"

@interface MainWindowObserver : NSObject {
}

- (id) init:(MainWindow::Private*)window;
- (void) activeSpaceDidChange:(NSNotification *)aNotification;
- (void) darkModeChanged:(NSNotification *)aNotification;
- (void) screenIsLocked:(NSNotification *)aNotification;
- (void) screenIsUnlocked:(NSNotification *)aNotification;
- (void) windowWillEnterFullScreen:(NSNotification *)aNotification;
- (void) windowWillExitFullScreen:(NSNotification *)aNotification;

@end // @interface MainWindowObserver

namespace Platform {
namespace {

// When we close a window that is fullscreen we first leave the fullscreen
// mode and after that hide the window. This is a timeout for elaving the
// fullscreen mode, after that we'll hide the window no matter what.
constexpr auto kHideAfterFullscreenTimeoutMs = 3000;

id FindClassInSubviews(NSView *parent, NSString *className) {
	for (NSView *child in [parent subviews]) {
		if ([child isKindOfClass:NSClassFromString(className)]) {
			return child;
		} else if (id inchild = FindClassInSubviews(child, className)) {
			return inchild;
		}
	}
	return nil;
}

#ifndef OS_MAC_OLD

class LayerCreationChecker : public QObject {
public:
	LayerCreationChecker(NSView * __weak view, Fn<void()> callback)
	: _weakView(view)
	, _callback(std::move(callback)) {
		QApplication::instance()->installEventFilter(this);
	}

protected:
	bool eventFilter(QObject *object, QEvent *event) override {
		if (!_weakView || [_weakView layer] != nullptr) {
			_callback();
		}
		return QObject::eventFilter(object, event);
	}

private:
	NSView * __weak _weakView = nil;
	Fn<void()> _callback;

};

#endif // OS_MAC_OLD

} // namespace

class MainWindow::Private {
public:
	Private(MainWindow *window);

	void setNativeWindow(NSWindow *window, NSView *view);
	void setWindowBadge(const QString &str);
	void setWindowTitle(const QString &str);
	void updateNativeTitle();

	void enableShadow(WId winId);

	bool filterNativeEvent(void *event);

	void willEnterFullScreen();
	void willExitFullScreen();

	bool clipboardHasText();

	TouchBar *_touchBar = nil;

	~Private();

private:
	void initCustomTitle();
	void refreshWeakTitleReferences();

	MainWindow *_public;
	friend class MainWindow;

#ifdef OS_MAC_OLD
	NSWindow *_nativeWindow = nil;
	NSView *_nativeView = nil;
#else // OS_MAC_OLD
	NSWindow * __weak _nativeWindow = nil;
	NSView * __weak _nativeView = nil;
	id __weak _nativeTitleWrapWeak = nil;
	id __weak _nativeTitleWeak = nil;
	std::unique_ptr<LayerCreationChecker> _layerCreationChecker;
#endif // !OS_MAC_OLD
	bool _useNativeTitle = false;
	bool _inFullScreen = false;

	MainWindowObserver *_observer;
	NSPasteboard *_generalPasteboard = nullptr;
	int _generalPasteboardChangeCount = -1;
	bool _generalPasteboardHasText = false;

};

} // namespace Platform

@implementation MainWindowObserver {
	MainWindow::Private *_private;

}

- (id) init:(MainWindow::Private*)window {
	if (self = [super init]) {
		_private = window;
	}
	return self;
}

- (void) activeSpaceDidChange:(NSNotification *)aNotification {
}

- (void) darkModeChanged:(NSNotification *)aNotification {
	Notify::unreadCounterUpdated();
}

- (void) screenIsLocked:(NSNotification *)aNotification {
	Global::SetScreenIsLocked(true);
}

- (void) screenIsUnlocked:(NSNotification *)aNotification {
	Global::SetScreenIsLocked(false);
}

- (void) windowWillEnterFullScreen:(NSNotification *)aNotification {
	_private->willEnterFullScreen();
}

- (void) windowWillExitFullScreen:(NSNotification *)aNotification {
	_private->willExitFullScreen();
}

@end // @implementation MainWindowObserver

namespace Platform {

MainWindow::Private::Private(MainWindow *window)
: _public(window)
, _observer([[MainWindowObserver alloc] init:this]) {
	_generalPasteboard = [NSPasteboard generalPasteboard];

	@autoreleasepool {

	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:_observer selector:@selector(activeSpaceDidChange:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
	[[NSDistributedNotificationCenter defaultCenter] addObserver:_observer selector:@selector(darkModeChanged:) name:Q2NSString(strNotificationAboutThemeChange()) object:nil];
	[[NSDistributedNotificationCenter defaultCenter] addObserver:_observer selector:@selector(screenIsLocked:) name:Q2NSString(strNotificationAboutScreenLocked()) object:nil];
	[[NSDistributedNotificationCenter defaultCenter] addObserver:_observer selector:@selector(screenIsUnlocked:) name:Q2NSString(strNotificationAboutScreenUnlocked()) object:nil];

#ifndef OS_MAC_STORE
	// Register defaults for the whitelist of apps that want to use media keys
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:[SPMediaKeyTap defaultMediaKeyUserBundleIdentifiers], kMediaKeyUsingBundleIdentifiersDefaultsKey, nil]];
#endif // !OS_MAC_STORE

	}
}

void MainWindow::Private::setWindowBadge(const QString &str) {
	@autoreleasepool {

	[[NSApp dockTile] setBadgeLabel:Q2NSString(str)];

	}
}

void MainWindow::Private::setWindowTitle(const QString &str) {
	_public->setWindowTitle(str);
	updateNativeTitle();
}

void MainWindow::Private::setNativeWindow(NSWindow *window, NSView *view) {
	_nativeWindow = window;
	_nativeView = view;
	initCustomTitle();
}

void MainWindow::Private::initCustomTitle() {
#ifndef OS_MAC_OLD
	if (![_nativeWindow respondsToSelector:@selector(contentLayoutRect)]
		|| ![_nativeWindow respondsToSelector:@selector(setTitlebarAppearsTransparent:)]) {
		return;
	}
	[_nativeWindow setTitlebarAppearsTransparent:YES];

	[[NSNotificationCenter defaultCenter] addObserver:_observer selector:@selector(windowWillEnterFullScreen:) name:NSWindowWillEnterFullScreenNotification object:_nativeWindow];
	[[NSNotificationCenter defaultCenter] addObserver:_observer selector:@selector(windowWillExitFullScreen:) name:NSWindowWillExitFullScreenNotification object:_nativeWindow];

	// Qt has bug with layer-backed widgets containing QOpenGLWidgets.
	// See https://bugreports.qt.io/browse/QTBUG-64494
	// Emulate custom title instead (code below).
	//
	// Tried to backport a fix, testing.
	[_nativeWindow setStyleMask:[_nativeWindow styleMask] | NSFullSizeContentViewWindowMask];
	auto inner = [_nativeWindow contentLayoutRect];
	auto full = [_nativeView frame];
	_public->_customTitleHeight = qMax(qRound(full.size.height - inner.size.height), 0);

	// Qt still has some bug with layer-backed widgets containing QOpenGLWidgets.
	// See https://github.com/telegramdesktop/tdesktop/issues/4150
	// Tried to workaround it by catching the first moment we have CALayer created
	// and explicitly setting contentsScale to window->backingScaleFactor there.
	_layerCreationChecker = std::make_unique<LayerCreationChecker>(_nativeView, [=] {
		if (_nativeView && _nativeWindow) {
			if (CALayer *layer = [_nativeView layer]) {
				LOG(("Window Info: Setting layer scale factor to: %1").arg([_nativeWindow backingScaleFactor]));
				[layer setContentsScale: [_nativeWindow backingScaleFactor]];
				_layerCreationChecker = nullptr;
			}
		} else {
			_layerCreationChecker = nullptr;
		}
	});

	// Disabled for now.
	//_useNativeTitle = true;
	//setWindowTitle(qsl("Telegram"));
#endif // !OS_MAC_OLD
}

void MainWindow::Private::refreshWeakTitleReferences() {
	if (!_nativeWindow) {
		return;
	}

#ifndef OS_MAC_OLD
	@autoreleasepool {

	if (NSView *parent = [[_nativeWindow contentView] superview]) {
		if (id titleWrap = FindClassInSubviews(parent, Q2NSString(strTitleWrapClass()))) {
			if ([titleWrap respondsToSelector:@selector(setBackgroundColor:)]) {
				if (id title = FindClassInSubviews(titleWrap, Q2NSString(strTitleClass()))) {
					if ([title respondsToSelector:@selector(setAttributedStringValue:)]) {
						_nativeTitleWrapWeak = titleWrap;
						_nativeTitleWeak = title;
					}
				}
			}
		}
	}

	}
#endif // !OS_MAC_OLD
}

void MainWindow::Private::updateNativeTitle() {
	if (!_useNativeTitle) {
		return;
	}
#ifndef OS_MAC_OLD
	if (!_nativeTitleWrapWeak || !_nativeTitleWeak) {
		refreshWeakTitleReferences();
	}
	if (_nativeTitleWrapWeak && _nativeTitleWeak) {
		@autoreleasepool {

		auto convertColor = [](QColor color) {
			return [NSColor colorWithDeviceRed:color.redF() green:color.greenF() blue:color.blueF() alpha:color.alphaF()];
		};
		auto adjustFg = [](const style::color &st) {
			// Weird thing with NSTextField taking NSAttributedString with
			// NSForegroundColorAttributeName set to colorWithDeviceRed:green:blue
			// with components all equal to 128 - it ignores it and prints black text!
			auto color = st->c;
			return (color.red() == 128 && color.green() == 128 && color.blue() == 128)
				? QColor(129, 129, 129, color.alpha())
				: color;
		};

		auto active = _public->isActiveWindow();
		auto bgColor = (active ? st::titleBgActive : st::titleBg)->c;
		auto fgColor = adjustFg(active ? st::titleFgActive : st::titleFg);

		auto bgConverted = convertColor(bgColor);
		auto fgConverted = convertColor(fgColor);
		[_nativeTitleWrapWeak setBackgroundColor:bgConverted];

		auto title = Q2NSString(_public->windowTitle());
		NSDictionary *attributes = _inFullScreen
			? nil
			: [NSDictionary dictionaryWithObjectsAndKeys: fgConverted, NSForegroundColorAttributeName, bgConverted, NSBackgroundColorAttributeName, nil];
		NSAttributedString *string = [[NSAttributedString alloc] initWithString:title attributes:attributes];
		[_nativeTitleWeak setAttributedStringValue:string];

		}
	}
#endif // !OS_MAC_OLD
}

bool MainWindow::Private::clipboardHasText() {
	auto currentChangeCount = static_cast<int>([_generalPasteboard changeCount]);
	if (_generalPasteboardChangeCount != currentChangeCount) {
		_generalPasteboardChangeCount = currentChangeCount;
		_generalPasteboardHasText = !QApplication::clipboard()->text().isEmpty();
	}
	return _generalPasteboardHasText;
}

void MainWindow::Private::willEnterFullScreen() {
	_inFullScreen = true;
	_public->setTitleVisible(false);
}

void MainWindow::Private::willExitFullScreen() {
	_inFullScreen = false;
	_public->setTitleVisible(true);
}

void MainWindow::Private::enableShadow(WId winId) {
//	[[(NSView*)winId window] setStyleMask:NSBorderlessWindowMask];
//	[[(NSView*)winId window] setHasShadow:YES];
}

bool MainWindow::Private::filterNativeEvent(void *event) {
	NSEvent *e = static_cast<NSEvent*>(event);
	if (e && [e type] == NSSystemDefined && [e subtype] == SPSystemDefinedEventMediaKeys) {
#ifndef OS_MAC_STORE
		// If event tap is not installed, handle events that reach the app instead
		if (![SPMediaKeyTap usesGlobalMediaKeyTap]) {
			return objc_handleMediaKeyEvent(e);
		}
#else // !OS_MAC_STORE
		return objc_handleMediaKeyEvent(e);
#endif // else for !OS_MAC_STORE
	}
	return false;
}

MainWindow::Private::~Private() {
	[_observer release];
}

MainWindow::MainWindow()
: _private(std::make_unique<Private>(this)) {
#ifndef OS_MAC_OLD
	auto forceOpenGL = std::make_unique<QOpenGLWidget>(this);
#endif // !OS_MAC_OLD

	trayImg = st::macTrayIcon.instance(QColor(0, 0, 0, 180), 100);
	trayImgSel = st::macTrayIcon.instance(QColor(255, 255, 255), 100);

	_hideAfterFullScreenTimer.setCallback([this] { hideAndDeactivate(); });

	subscribe(Window::Theme::Background(), [this](const Window::Theme::BackgroundUpdate &data) {
		if (data.paletteChanged()) {
			_private->updateNativeTitle();
		}
	});

	initTouchBar();
}

void MainWindow::initTouchBar() {
	if (!IsMac10_13OrGreater()) {
		return;
	}

	subscribe(Core::App().authSessionChanged(), [this] {
		if (AuthSession::Exists()) {
			// We need only common pinned dialogs.
			if (!_private->_touchBar) {
				if (auto view = reinterpret_cast<NSView*>(winId())) {
					// Create TouchBar.
					[NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = YES;
					_private->_touchBar = [[TouchBar alloc] init:view];
				}
			}
		} else {
			if (_private->_touchBar) {
				[_private->_touchBar setTouchBar:Platform::TouchBarType::None];
				[_private->_touchBar release];
			}
			_private->_touchBar = nil;
		}
	});
}

void MainWindow::closeWithoutDestroy() {
	NSWindow *nsWindow = [reinterpret_cast<NSView*>(winId()) window];

	auto isFullScreen = (([nsWindow styleMask] & NSFullScreenWindowMask) == NSFullScreenWindowMask);
	if (isFullScreen) {
		_hideAfterFullScreenTimer.callOnce(kHideAfterFullscreenTimeoutMs);
		[nsWindow toggleFullScreen:nsWindow];
	} else {
		hideAndDeactivate();
	}
}

void MainWindow::stateChangedHook(Qt::WindowState state) {
	if (_hideAfterFullScreenTimer.isActive()) {
		_hideAfterFullScreenTimer.callOnce(0);
	}
}

void MainWindow::handleActiveChangedHook() {
	InvokeQueued(this, [this] { _private->updateNativeTitle(); });
}

void MainWindow::initHook() {
	_customTitleHeight = 0;
	if (auto view = reinterpret_cast<NSView*>(winId())) {
		if (auto window = [view window]) {
			_private->setNativeWindow(window, view);
		}
	}
}

void MainWindow::updateWindowIcon() {
}

void MainWindow::titleVisibilityChangedHook() {
	updateTitleCounter();
}

void MainWindow::hideAndDeactivate() {
	hide();
}

QImage MainWindow::psTrayIcon(bool selected) const {
	return selected ? trayImgSel : trayImg;
}

void MainWindow::psShowTrayMenu() {
}

void MainWindow::psTrayMenuUpdated() {
}

void MainWindow::psSetupTrayIcon() {
	if (!trayIcon) {
		trayIcon = new QSystemTrayIcon(this);

		QIcon icon(QPixmap::fromImage(psTrayIcon(), Qt::ColorOnly));
		icon.addPixmap(QPixmap::fromImage(psTrayIcon(true), Qt::ColorOnly), QIcon::Selected);

		trayIcon->setIcon(icon);
		attachToTrayIcon(trayIcon);
	}
	updateIconCounters();

	trayIcon->show();
}

void MainWindow::workmodeUpdated(DBIWorkMode mode) {
	psSetupTrayIcon();
	if (mode == dbiwmWindowOnly) {
		if (trayIcon) {
			trayIcon->setContextMenu(0);
			delete trayIcon;
			trayIcon = nullptr;
		}
	}
}

void _placeCounter(QImage &img, int size, int count, style::color bg, style::color color) {
	if (!count) return;
	auto savedRatio = img.devicePixelRatio();
	img.setDevicePixelRatio(1.);

	{
		Painter p(&img);
		PainterHighQualityEnabler hq(p);

		auto cnt = (count < 100) ? QString("%1").arg(count) : QString("..%1").arg(count % 100, 2, 10, QChar('0'));
		auto cntSize = cnt.size();

		p.setBrush(bg);
		p.setPen(Qt::NoPen);
		int32 fontSize, skip;
		if (size == 22) {
			skip = 1;
			fontSize = 8;
		} else {
			skip = 2;
			fontSize = 16;
		}
		style::font f(fontSize, 0, 0);
		int32 w = f->width(cnt), d, r;
		if (size == 22) {
			d = (cntSize < 2) ? 3 : 2;
			r = (cntSize < 2) ? 6 : 5;
		} else {
			d = (cntSize < 2) ? 6 : 5;
			r = (cntSize < 2) ? 9 : 11;
		}
		p.drawRoundedRect(QRect(size - w - d * 2 - skip, size - f->height - skip, w + d * 2, f->height), r, r);

		p.setCompositionMode(QPainter::CompositionMode_Source);
		p.setFont(f);
		p.setPen(color);
		p.drawText(size - w - d - skip, size - f->height + f->ascent - skip, cnt);
	}
	img.setDevicePixelRatio(savedRatio);
}

void MainWindow::updateTitleCounter() {
	_private->setWindowTitle(titleVisible() ? QString() : titleText());
}

void MainWindow::unreadCounterChangedHook() {
	updateTitleCounter();
	updateIconCounters();
}

void MainWindow::updateIconCounters() {
	const auto counter = Core::App().unreadBadge();
	const auto muted = Core::App().unreadBadgeMuted();

	const auto string = !counter
		? QString()
		: (counter < 1000)
		? QString("%1").arg(counter)
		: QString("..%1").arg(counter % 100, 2, 10, QChar('0'));
	_private->setWindowBadge(string);

	if (trayIcon) {
		bool dm = objc_darkMode();
		auto &bg = (muted ? st::trayCounterBgMute : st::trayCounterBg);
		QIcon icon;
		QImage img(psTrayIcon(dm)), imgsel(psTrayIcon(true));
		img.detach();
		imgsel.detach();
		int32 size = 22 * cIntRetinaFactor();
		_placeCounter(img, size, counter, bg, (dm && muted) ? st::trayCounterFgMacInvert : st::trayCounterFg);
		_placeCounter(imgsel, size, counter, st::trayCounterBgMacInvert, st::trayCounterFgMacInvert);
		icon.addPixmap(App::pixmapFromImageInPlace(std::move(img)));
		icon.addPixmap(App::pixmapFromImageInPlace(std::move(imgsel)), QIcon::Selected);
		trayIcon->setIcon(icon);
	}
}

void MainWindow::psFirstShow() {
	psUpdateMargins();

	bool showShadows = true;

	show();
	_private->enableShadow(winId());
	if (cWindowPos().maximized) {
		DEBUG_LOG(("Window Pos: First show, setting maximized."));
		setWindowState(Qt::WindowMaximized);
	}

	if ((cLaunchMode() == LaunchModeAutoStart && cStartMinimized()) || cStartInTray()) {
		setWindowState(Qt::WindowMinimized);
		if (Global::WorkMode().value() == dbiwmTrayOnly || Global::WorkMode().value() == dbiwmWindowAndTray) {
			hide();
		} else {
			show();
		}
		showShadows = false;
	} else {
		show();
	}

	setPositionInited();

	createGlobalMenu();
}

void MainWindow::createGlobalMenu() {
	auto main = psMainMenu.addMenu(qsl("Telegram"));
	auto about = main->addAction(lng_mac_menu_about_telegram(lt_telegram, qsl("Telegram")));
	connect(about, &QAction::triggered, about, [] {
		if (App::wnd() && App::wnd()->isHidden()) App::wnd()->showFromTray();
		Ui::show(Box<AboutBox>());
	});
	about->setMenuRole(QAction::AboutQtRole);

	main->addSeparator();
	QAction *prefs = main->addAction(lang(lng_mac_menu_preferences), App::wnd(), SLOT(showSettings()), QKeySequence(Qt::ControlModifier | Qt::Key_Comma));
	prefs->setMenuRole(QAction::PreferencesRole);

	QMenu *file = psMainMenu.addMenu(lang(lng_mac_menu_file));
	psLogout = file->addAction(lang(lng_mac_menu_logout), App::wnd(), SLOT(onLogout()));

	QMenu *edit = psMainMenu.addMenu(lang(lng_mac_menu_edit));
	psUndo = edit->addAction(lang(lng_mac_menu_undo), this, SLOT(psMacUndo()), QKeySequence::Undo);
	psRedo = edit->addAction(lang(lng_mac_menu_redo), this, SLOT(psMacRedo()), QKeySequence::Redo);
	edit->addSeparator();
	psCut = edit->addAction(lang(lng_mac_menu_cut), this, SLOT(psMacCut()), QKeySequence::Cut);
	psCopy = edit->addAction(lang(lng_mac_menu_copy), this, SLOT(psMacCopy()), QKeySequence::Copy);
	psPaste = edit->addAction(lang(lng_mac_menu_paste), this, SLOT(psMacPaste()), QKeySequence::Paste);
	psDelete = edit->addAction(lang(lng_mac_menu_delete), this, SLOT(psMacDelete()), QKeySequence(Qt::ControlModifier | Qt::Key_Backspace));
	edit->addSeparator();
	psSelectAll = edit->addAction(lang(lng_mac_menu_select_all), this, SLOT(psMacSelectAll()), QKeySequence::SelectAll);

	QMenu *window = psMainMenu.addMenu(lang(lng_mac_menu_window));
	psContacts = window->addAction(lang(lng_mac_menu_contacts));
	connect(psContacts, &QAction::triggered, psContacts, [] {
		if (App::wnd() && App::wnd()->isHidden()) App::wnd()->showFromTray();

		if (!AuthSession::Exists()) return;
		Ui::show(Box<PeerListBox>(std::make_unique<ContactsBoxController>(), [](not_null<PeerListBox*> box) {
			box->addButton(langFactory(lng_close), [box] { box->closeBox(); });
			box->addLeftButton(langFactory(lng_profile_add_contact), [] { App::wnd()->onShowAddContact(); });
		}));
	});
	psAddContact = window->addAction(lang(lng_mac_menu_add_contact), App::wnd(), SLOT(onShowAddContact()));
	window->addSeparator();
	psNewGroup = window->addAction(lang(lng_mac_menu_new_group), App::wnd(), SLOT(onShowNewGroup()));
	psNewChannel = window->addAction(lang(lng_mac_menu_new_channel), App::wnd(), SLOT(onShowNewChannel()));
	window->addSeparator();
	psShowTelegram = window->addAction(lang(lng_mac_menu_show), App::wnd(), SLOT(showFromTray()));

	updateGlobalMenu();
}

namespace {
	void _sendKeySequence(Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
		QWidget *focused = QApplication::focusWidget();
		if (qobject_cast<QLineEdit*>(focused) || qobject_cast<QTextEdit*>(focused) || qobject_cast<HistoryInner*>(focused)) {
			QApplication::postEvent(focused, new QKeyEvent(QEvent::KeyPress, key, modifiers));
			QApplication::postEvent(focused, new QKeyEvent(QEvent::KeyRelease, key, modifiers));
		}
	}
	void _forceDisabled(QAction *action, bool disabled) {
		if (action->isEnabled()) {
			if (disabled) action->setDisabled(true);
		} else if (!disabled) {
			action->setDisabled(false);
		}
	}
}

void MainWindow::psMacUndo() {
	_sendKeySequence(Qt::Key_Z, Qt::ControlModifier);
}

void MainWindow::psMacRedo() {
	_sendKeySequence(Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
}

void MainWindow::psMacCut() {
	_sendKeySequence(Qt::Key_X, Qt::ControlModifier);
}

void MainWindow::psMacCopy() {
	_sendKeySequence(Qt::Key_C, Qt::ControlModifier);
}

void MainWindow::psMacPaste() {
	_sendKeySequence(Qt::Key_V, Qt::ControlModifier);
}

void MainWindow::psMacDelete() {
	_sendKeySequence(Qt::Key_Delete);
}

void MainWindow::psMacSelectAll() {
	_sendKeySequence(Qt::Key_A, Qt::ControlModifier);
}

void MainWindow::psInitSysMenu() {
}

void MainWindow::psUpdateMargins() {
}

void MainWindow::updateGlobalMenuHook() {
	if (!App::wnd() || !positionInited()) return;

	auto focused = QApplication::focusWidget();
	bool canUndo = false, canRedo = false, canCut = false, canCopy = false, canPaste = false, canDelete = false, canSelectAll = false;
	auto clipboardHasText = _private->clipboardHasText();
	if (auto edit = qobject_cast<QLineEdit*>(focused)) {
		canCut = canCopy = canDelete = edit->hasSelectedText();
		canSelectAll = !edit->text().isEmpty();
		canUndo = edit->isUndoAvailable();
		canRedo = edit->isRedoAvailable();
		canPaste = clipboardHasText;
	} else if (auto edit = qobject_cast<QTextEdit*>(focused)) {
		canCut = canCopy = canDelete = edit->textCursor().hasSelection();
		canSelectAll = !edit->document()->isEmpty();
		canUndo = edit->document()->isUndoAvailable();
		canRedo = edit->document()->isRedoAvailable();
		canPaste = clipboardHasText;
	} else if (auto list = qobject_cast<HistoryInner*>(focused)) {
		canCopy = list->canCopySelected();
		canDelete = list->canDeleteSelected();
	}
	App::wnd()->updateIsActive(0);
	const auto logged = AuthSession::Exists();
	const auto locked = Core::App().locked();
	const auto inactive = !logged || locked;
	const auto support = logged && Auth().supportMode();
	_forceDisabled(psLogout, !logged && !locked);
	_forceDisabled(psUndo, !canUndo);
	_forceDisabled(psRedo, !canRedo);
	_forceDisabled(psCut, !canCut);
	_forceDisabled(psCopy, !canCopy);
	_forceDisabled(psPaste, !canPaste);
	_forceDisabled(psDelete, !canDelete);
	_forceDisabled(psSelectAll, !canSelectAll);
	_forceDisabled(psContacts, inactive || support);
	_forceDisabled(psAddContact, inactive);
	_forceDisabled(psNewGroup, inactive || support);
	_forceDisabled(psNewChannel, inactive || support);
	_forceDisabled(psShowTelegram, App::wnd()->isActive());
}

bool MainWindow::psFilterNativeEvent(void *event) {
	return _private->filterNativeEvent(event);
}

bool MainWindow::eventFilter(QObject *obj, QEvent *evt) {
	QEvent::Type t = evt->type();
	if (t == QEvent::FocusIn || t == QEvent::FocusOut) {
		if (qobject_cast<QLineEdit*>(obj) || qobject_cast<QTextEdit*>(obj) || qobject_cast<HistoryInner*>(obj)) {
			updateGlobalMenu();
		}
	}
	return Window::MainWindow::eventFilter(obj, evt);
}

MainWindow::~MainWindow() {
}

} // namespace
