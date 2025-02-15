/*
This file is part of Telegram Desktop,
the official desktop application for the Telegram messaging service.

For license and copyright information please follow this link:
https://github.com/telegramdesktop/tdesktop/blob/master/LEGAL
*/
#include "auth_session.h"

#include "apiwrap.h"
#include "core/application.h"
#include "core/changelogs.h"
#include "storage/file_download.h"
#include "storage/file_upload.h"
#include "storage/localstorage.h"
#include "storage/storage_facade.h"
#include "storage/serialize_common.h"
#include "data/data_session.h"
#include "data/data_user.h"
#include "window/notifications_manager.h"
#include "window/themes/window_theme.h"
#include "platform/platform_specific.h"
#include "calls/calls_instance.h"
#include "window/section_widget.h"
#include "chat_helpers/tabbed_selector.h"
#include "boxes/send_files_box.h"
#include "ui/widgets/input_fields.h"
#include "support/support_common.h"
#include "support/support_helper.h"
#include "observer_peer.h"

namespace {

constexpr auto kAutoLockTimeoutLateMs = crl::time(3000);
constexpr auto kLegacyCallsPeerToPeerNobody = 4;

} // namespace

AuthSessionSettings::Variables::Variables()
: sendFilesWay(SendFilesWay::Album)
, selectorTab(ChatHelpers::SelectorTab::Emoji)
, floatPlayerColumn(Window::Column::Second)
, floatPlayerCorner(RectPart::TopRight)
, sendSubmitWay(Ui::InputSubmitSettings::Enter)
, supportSwitch(Support::SwitchSettings::Next) {
}

QByteArray AuthSessionSettings::serialize() const {
	const auto autoDownload = _variables.autoDownload.serialize();
	auto size = sizeof(qint32) * 23;
	for (auto i = _variables.soundOverrides.cbegin(), e = _variables.soundOverrides.cend(); i != e; ++i) {
		size += Serialize::stringSize(i.key()) + Serialize::stringSize(i.value());
	}
	size += _variables.groupStickersSectionHidden.size() * sizeof(quint64);
	size += Serialize::bytearraySize(autoDownload);

	auto result = QByteArray();
	result.reserve(size);
	{
		QDataStream stream(&result, QIODevice::WriteOnly);
		stream.setVersion(QDataStream::Qt_5_1);
		stream << static_cast<qint32>(_variables.selectorTab);
		stream << qint32(_variables.lastSeenWarningSeen ? 1 : 0);
		stream << qint32(_variables.tabbedSelectorSectionEnabled ? 1 : 0);
		stream << qint32(_variables.soundOverrides.size());
		for (auto i = _variables.soundOverrides.cbegin(), e = _variables.soundOverrides.cend(); i != e; ++i) {
			stream << i.key() << i.value();
		}
		stream << qint32(_variables.tabbedSelectorSectionTooltipShown);
		stream << qint32(_variables.floatPlayerColumn);
		stream << qint32(_variables.floatPlayerCorner);
		stream << qint32(_variables.groupStickersSectionHidden.size());
		for (auto peerId : _variables.groupStickersSectionHidden) {
			stream << quint64(peerId);
		}
		stream << qint32(_variables.thirdSectionInfoEnabled ? 1 : 0);
		stream << qint32(_variables.smallDialogsList ? 1 : 0);
		stream << qint32(snap(
			qRound(_variables.dialogsWidthRatio.current() * 1000000),
			0,
			1000000));
		stream << qint32(_variables.thirdColumnWidth.current());
		stream << qint32(_variables.thirdSectionExtendedBy);
		stream << qint32(_variables.sendFilesWay);
		stream << qint32(0);// LEGACY _variables.callsPeerToPeer.current());
		stream << qint32(_variables.sendSubmitWay);
		stream << qint32(_variables.supportSwitch);
		stream << qint32(_variables.supportFixChatsOrder ? 1 : 0);
		stream << qint32(_variables.supportTemplatesAutocomplete ? 1 : 0);
		stream << qint32(_variables.supportChatsTimeSlice.current());
		stream << qint32(_variables.includeMutedCounter ? 1 : 0);
		stream << qint32(_variables.countUnreadMessages ? 1 : 0);
		stream << qint32(_variables.exeLaunchWarning ? 1 : 0);
		stream << autoDownload;
		stream << qint32(_variables.supportAllSearchResults.current() ? 1 : 0);
		stream << qint32(_variables.archiveCollapsed.current() ? 1 : 0);
		stream << qint32(_variables.notifyAboutPinned.current() ? 1 : 0);
	}
	return result;
}

void AuthSessionSettings::constructFromSerialized(const QByteArray &serialized) {
	if (serialized.isEmpty()) {
		return;
	}

	QDataStream stream(serialized);
	stream.setVersion(QDataStream::Qt_5_1);
	qint32 selectorTab = static_cast<qint32>(ChatHelpers::SelectorTab::Emoji);
	qint32 lastSeenWarningSeen = 0;
	qint32 tabbedSelectorSectionEnabled = 1;
	qint32 tabbedSelectorSectionTooltipShown = 0;
	qint32 floatPlayerColumn = static_cast<qint32>(Window::Column::Second);
	qint32 floatPlayerCorner = static_cast<qint32>(RectPart::TopRight);
	QMap<QString, QString> soundOverrides;
	base::flat_set<PeerId> groupStickersSectionHidden;
	qint32 thirdSectionInfoEnabled = 0;
	qint32 smallDialogsList = 0;
	float64 dialogsWidthRatio = _variables.dialogsWidthRatio.current();
	int thirdColumnWidth = _variables.thirdColumnWidth.current();
	int thirdSectionExtendedBy = _variables.thirdSectionExtendedBy;
	qint32 sendFilesWay = static_cast<qint32>(_variables.sendFilesWay);
	qint32 legacyCallsPeerToPeer = qint32(0);
	qint32 sendSubmitWay = static_cast<qint32>(_variables.sendSubmitWay);
	qint32 supportSwitch = static_cast<qint32>(_variables.supportSwitch);
	qint32 supportFixChatsOrder = _variables.supportFixChatsOrder ? 1 : 0;
	qint32 supportTemplatesAutocomplete = _variables.supportTemplatesAutocomplete ? 1 : 0;
	qint32 supportChatsTimeSlice = _variables.supportChatsTimeSlice.current();
	qint32 includeMutedCounter = _variables.includeMutedCounter ? 1 : 0;
	qint32 countUnreadMessages = _variables.countUnreadMessages ? 1 : 0;
	qint32 exeLaunchWarning = _variables.exeLaunchWarning ? 1 : 0;
	QByteArray autoDownload;
	qint32 supportAllSearchResults = _variables.supportAllSearchResults.current() ? 1 : 0;
	qint32 archiveCollapsed = _variables.archiveCollapsed.current() ? 1 : 0;
	qint32 notifyAboutPinned = _variables.notifyAboutPinned.current() ? 1 : 0;

	stream >> selectorTab;
	stream >> lastSeenWarningSeen;
	if (!stream.atEnd()) {
		stream >> tabbedSelectorSectionEnabled;
	}
	if (!stream.atEnd()) {
		auto count = qint32(0);
		stream >> count;
		if (stream.status() == QDataStream::Ok) {
			for (auto i = 0; i != count; ++i) {
				QString key, value;
				stream >> key >> value;
				soundOverrides[key] = value;
			}
		}
	}
	if (!stream.atEnd()) {
		stream >> tabbedSelectorSectionTooltipShown;
	}
	if (!stream.atEnd()) {
		stream >> floatPlayerColumn >> floatPlayerCorner;
	}
	if (!stream.atEnd()) {
		auto count = qint32(0);
		stream >> count;
		if (stream.status() == QDataStream::Ok) {
			for (auto i = 0; i != count; ++i) {
				quint64 peerId;
				stream >> peerId;
				groupStickersSectionHidden.insert(peerId);
			}
		}
	}
	if (!stream.atEnd()) {
		stream >> thirdSectionInfoEnabled;
		stream >> smallDialogsList;
	}
	if (!stream.atEnd()) {
		qint32 value = 0;
		stream >> value;
		dialogsWidthRatio = snap(value / 1000000., 0., 1.);

		stream >> value;
		thirdColumnWidth = value;

		stream >> value;
		thirdSectionExtendedBy = value;
	}
	if (!stream.atEnd()) {
		stream >> sendFilesWay;
	}
	if (!stream.atEnd()) {
		stream >> legacyCallsPeerToPeer;
	}
	if (!stream.atEnd()) {
		stream >> sendSubmitWay;
		stream >> supportSwitch;
		stream >> supportFixChatsOrder;
	}
	if (!stream.atEnd()) {
		stream >> supportTemplatesAutocomplete;
	}
	if (!stream.atEnd()) {
		stream >> supportChatsTimeSlice;
	}
	if (!stream.atEnd()) {
		stream >> includeMutedCounter;
		stream >> countUnreadMessages;
	}
	if (!stream.atEnd()) {
		stream >> exeLaunchWarning;
	}
	if (!stream.atEnd()) {
		stream >> autoDownload;
	}
	if (!stream.atEnd()) {
		stream >> supportAllSearchResults;
	}
	if (!stream.atEnd()) {
		stream >> archiveCollapsed;
	}
	if (!stream.atEnd()) {
		stream >> notifyAboutPinned;
	}
	if (stream.status() != QDataStream::Ok) {
		LOG(("App Error: "
			"Bad data for AuthSessionSettings::constructFromSerialized()"));
		return;
	}
	if (!autoDownload.isEmpty()
		&& !_variables.autoDownload.setFromSerialized(autoDownload)) {
		return;
	}

	auto uncheckedTab = static_cast<ChatHelpers::SelectorTab>(selectorTab);
	switch (uncheckedTab) {
	case ChatHelpers::SelectorTab::Emoji:
	case ChatHelpers::SelectorTab::Stickers:
	case ChatHelpers::SelectorTab::Gifs: _variables.selectorTab = uncheckedTab; break;
	}
	_variables.lastSeenWarningSeen = (lastSeenWarningSeen == 1);
	_variables.tabbedSelectorSectionEnabled = (tabbedSelectorSectionEnabled == 1);
	_variables.soundOverrides = std::move(soundOverrides);
	_variables.tabbedSelectorSectionTooltipShown = tabbedSelectorSectionTooltipShown;
	auto uncheckedColumn = static_cast<Window::Column>(floatPlayerColumn);
	switch (uncheckedColumn) {
	case Window::Column::First:
	case Window::Column::Second:
	case Window::Column::Third: _variables.floatPlayerColumn = uncheckedColumn; break;
	}
	auto uncheckedCorner = static_cast<RectPart>(floatPlayerCorner);
	switch (uncheckedCorner) {
	case RectPart::TopLeft:
	case RectPart::TopRight:
	case RectPart::BottomLeft:
	case RectPart::BottomRight: _variables.floatPlayerCorner = uncheckedCorner; break;
	}
	_variables.groupStickersSectionHidden = std::move(groupStickersSectionHidden);
	_variables.thirdSectionInfoEnabled = thirdSectionInfoEnabled;
	_variables.smallDialogsList = smallDialogsList;
	_variables.dialogsWidthRatio = dialogsWidthRatio;
	_variables.thirdColumnWidth = thirdColumnWidth;
	_variables.thirdSectionExtendedBy = thirdSectionExtendedBy;
	if (_variables.thirdSectionInfoEnabled) {
		_variables.tabbedSelectorSectionEnabled = false;
	}
	auto uncheckedSendFilesWay = static_cast<SendFilesWay>(sendFilesWay);
	switch (uncheckedSendFilesWay) {
	case SendFilesWay::Album:
	case SendFilesWay::Photos:
	case SendFilesWay::Files: _variables.sendFilesWay = uncheckedSendFilesWay; break;
	}
	auto uncheckedSendSubmitWay = static_cast<Ui::InputSubmitSettings>(
		sendSubmitWay);
	switch (uncheckedSendSubmitWay) {
	case Ui::InputSubmitSettings::Enter:
	case Ui::InputSubmitSettings::CtrlEnter: _variables.sendSubmitWay = uncheckedSendSubmitWay; break;
	}
	auto uncheckedSupportSwitch = static_cast<Support::SwitchSettings>(
		supportSwitch);
	switch (uncheckedSupportSwitch) {
	case Support::SwitchSettings::None:
	case Support::SwitchSettings::Next:
	case Support::SwitchSettings::Previous: _variables.supportSwitch = uncheckedSupportSwitch; break;
	}
	_variables.supportFixChatsOrder = (supportFixChatsOrder == 1);
	_variables.supportTemplatesAutocomplete = (supportTemplatesAutocomplete == 1);
	_variables.supportChatsTimeSlice = supportChatsTimeSlice;
	_variables.hadLegacyCallsPeerToPeerNobody = (legacyCallsPeerToPeer == kLegacyCallsPeerToPeerNobody);
	_variables.includeMutedCounter = (includeMutedCounter == 1);
	_variables.countUnreadMessages = (countUnreadMessages == 1);
	_variables.exeLaunchWarning = (exeLaunchWarning == 1);
	_variables.supportAllSearchResults = (supportAllSearchResults == 1);
	_variables.archiveCollapsed = (archiveCollapsed == 1);
	_variables.notifyAboutPinned = (notifyAboutPinned == 1);
}

void AuthSessionSettings::setSupportChatsTimeSlice(int slice) {
	_variables.supportChatsTimeSlice = slice;
}

int AuthSessionSettings::supportChatsTimeSlice() const {
	return _variables.supportChatsTimeSlice.current();
}

rpl::producer<int> AuthSessionSettings::supportChatsTimeSliceValue() const {
	return _variables.supportChatsTimeSlice.value();
}

void AuthSessionSettings::setSupportAllSearchResults(bool all) {
	_variables.supportAllSearchResults = all;
}

bool AuthSessionSettings::supportAllSearchResults() const {
	return _variables.supportAllSearchResults.current();
}

rpl::producer<bool> AuthSessionSettings::supportAllSearchResultsValue() const {
	return _variables.supportAllSearchResults.value();
}

void AuthSessionSettings::setTabbedSelectorSectionEnabled(bool enabled) {
	_variables.tabbedSelectorSectionEnabled = enabled;
	if (enabled) {
		setThirdSectionInfoEnabled(false);
	}
	setTabbedReplacedWithInfo(false);
}

rpl::producer<bool> AuthSessionSettings::tabbedReplacedWithInfoValue() const {
	return _tabbedReplacedWithInfoValue.events_starting_with(
		tabbedReplacedWithInfo());
}

void AuthSessionSettings::setThirdSectionInfoEnabled(bool enabled) {
	if (_variables.thirdSectionInfoEnabled != enabled) {
		_variables.thirdSectionInfoEnabled = enabled;
		if (enabled) {
			setTabbedSelectorSectionEnabled(false);
		}
		setTabbedReplacedWithInfo(false);
		_thirdSectionInfoEnabledValue.fire_copy(enabled);
	}
}

rpl::producer<bool> AuthSessionSettings::thirdSectionInfoEnabledValue() const {
	return _thirdSectionInfoEnabledValue.events_starting_with(
		thirdSectionInfoEnabled());
}

void AuthSessionSettings::setTabbedReplacedWithInfo(bool enabled) {
	if (_tabbedReplacedWithInfo != enabled) {
		_tabbedReplacedWithInfo = enabled;
		_tabbedReplacedWithInfoValue.fire_copy(enabled);
	}
}

QString AuthSessionSettings::getSoundPath(const QString &key) const {
	auto it = _variables.soundOverrides.constFind(key);
	if (it != _variables.soundOverrides.end()) {
		return it.value();
	}
	return qsl(":/sounds/") + key + qsl(".mp3");
}

void AuthSessionSettings::setDialogsWidthRatio(float64 ratio) {
	_variables.dialogsWidthRatio = ratio;
}

float64 AuthSessionSettings::dialogsWidthRatio() const {
	return _variables.dialogsWidthRatio.current();
}

rpl::producer<float64> AuthSessionSettings::dialogsWidthRatioChanges() const {
	return _variables.dialogsWidthRatio.changes();
}

void AuthSessionSettings::setThirdColumnWidth(int width) {
	_variables.thirdColumnWidth = width;
}

int AuthSessionSettings::thirdColumnWidth() const {
	return _variables.thirdColumnWidth.current();
}

rpl::producer<int> AuthSessionSettings::thirdColumnWidthChanges() const {
	return _variables.thirdColumnWidth.changes();
}

void AuthSessionSettings::setArchiveCollapsed(bool collapsed) {
	_variables.archiveCollapsed = collapsed;
}

bool AuthSessionSettings::archiveCollapsed() const {
	return _variables.archiveCollapsed.current();
}

rpl::producer<bool> AuthSessionSettings::archiveCollapsedChanges() const {
	return _variables.archiveCollapsed.changes();
}

void AuthSessionSettings::setNotifyAboutPinned(bool notify) {
	_variables.notifyAboutPinned = notify;
}

bool AuthSessionSettings::notifyAboutPinned() const {
	return _variables.notifyAboutPinned.current();
}

rpl::producer<bool> AuthSessionSettings::notifyAboutPinnedChanges() const {
	return _variables.notifyAboutPinned.changes();
}

AuthSession &Auth() {
	const auto result = Core::App().authSession();
	Assert(result != nullptr);
	return *result;
}

AuthSession::AuthSession(const MTPUser &user)
: _autoLockTimer([this] { checkAutoLock(); })
, _api(std::make_unique<ApiWrap>(this))
, _calls(std::make_unique<Calls::Instance>())
, _downloader(std::make_unique<Storage::Downloader>(_api.get()))
, _uploader(std::make_unique<Storage::Uploader>(_api.get()))
, _storage(std::make_unique<Storage::Facade>())
, _notifications(std::make_unique<Window::Notifications::System>(this))
, _data(std::make_unique<Data::Session>(this))
, _user(_data->processUser(user))
, _changelogs(Core::Changelogs::Create(this))
, _supportHelper(Support::Helper::Create(this)) {

	_saveDataTimer.setCallback([=] {
		Local::writeUserSettings();
	});
	Core::App().passcodeLockChanges(
	) | rpl::start_with_next([=] {
		_shouldLockAt = 0;
	}, _lifetime);
	Core::App().lockChanges(
	) | rpl::start_with_next([=] {
		notifications().updateAll();
	}, _lifetime);
	subscribe(Global::RefConnectionTypeChanged(), [=] {
		_api->refreshProxyPromotion();
	});
	_api->refreshProxyPromotion();
	_api->requestTermsUpdate();
	_api->requestFullPeer(_user);

	crl::on_main(this, [=] {
		using Flag = Notify::PeerUpdate::Flag;
		const auto events = Flag::NameChanged
			| Flag::UsernameChanged
			| Flag::PhotoChanged
			| Flag::AboutChanged
			| Flag::UserPhoneChanged;
		subscribe(
			Notify::PeerUpdated(),
			Notify::PeerUpdatedHandler(
				events,
				[=](const Notify::PeerUpdate &update) {
					if (update.peer == _user) {
						Local::writeSelf();
					}
				}));
	});

	Window::Theme::Background()->start();
}

bool AuthSession::Exists() {
	return Core::IsAppLaunched() && (Core::App().authSession() != nullptr);
}

base::Observable<void> &AuthSession::downloaderTaskFinished() {
	return downloader().taskFinished();
}

UserId AuthSession::userId() const {
	return _user->bareId();
}

PeerId AuthSession::userPeerId() const {
	return _user->id;
}

bool AuthSession::validateSelf(const MTPUser &user) {
	if (user.type() != mtpc_user || !user.c_user().is_self()) {
		LOG(("API Error: bad self user received."));
		return false;
	} else if (user.c_user().vid.v != userId()) {
		LOG(("Auth Error: wrong self user received."));
		crl::on_main(this, [] { Core::App().logOut(); });
		return false;
	}
	return true;
}

void AuthSession::moveSettingsFrom(AuthSessionSettings &&other) {
	_settings.moveFrom(std::move(other));
	if (_settings.hadLegacyCallsPeerToPeerNobody()) {
		api().savePrivacy(
			MTP_inputPrivacyKeyPhoneP2P(),
			QVector<MTPInputPrivacyRule>(
				1,
				MTP_inputPrivacyValueDisallowAll()));
		saveSettingsDelayed();
	}
}

void AuthSession::saveSettingsDelayed(crl::time delay) {
	Expects(this == &Auth());

	_saveDataTimer.callOnce(delay);
}

void AuthSession::localPasscodeChanged() {
	_shouldLockAt = 0;
	_autoLockTimer.cancel();
	checkAutoLock();
}

void AuthSession::termsDeleteNow() {
	api().request(MTPaccount_DeleteAccount(
		MTP_string("Decline ToS update")
	)).send();
}

void AuthSession::checkAutoLock() {
	if (!Global::LocalPasscode()
		|| Core::App().passcodeLocked()) {
		_shouldLockAt = 0;
		_autoLockTimer.cancel();
		return;
	}

	Core::App().checkLocalTime();
	const auto now = crl::now();
	const auto shouldLockInMs = Global::AutoLock() * 1000LL;
	const auto checkTimeMs = now - Core::App().lastNonIdleTime();
	if (checkTimeMs >= shouldLockInMs || (_shouldLockAt > 0 && now > _shouldLockAt + kAutoLockTimeoutLateMs)) {
		_shouldLockAt = 0;
		_autoLockTimer.cancel();
		Core::App().lockByPasscode();
	} else {
		_shouldLockAt = now + (shouldLockInMs - checkTimeMs);
		_autoLockTimer.callOnce(shouldLockInMs - checkTimeMs);
	}
}

void AuthSession::checkAutoLockIn(crl::time time) {
	if (_autoLockTimer.isActive()) {
		auto remain = _autoLockTimer.remainingTime();
		if (remain > 0 && remain <= time) return;
	}
	_autoLockTimer.callOnce(time);
}

bool AuthSession::supportMode() const {
	return (_supportHelper != nullptr);
}

Support::Helper &AuthSession::supportHelper() const {
	Expects(supportMode());

	return *_supportHelper;
}

Support::Templates& AuthSession::supportTemplates() const {
	return supportHelper().templates();
}

AuthSession::~AuthSession() {
	ClickHandler::clearActive();
	ClickHandler::unpressed();
}
