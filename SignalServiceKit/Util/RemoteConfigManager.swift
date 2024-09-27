//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import LibSignalClient

public class RemoteConfig {

    public static var current: RemoteConfig {
        return NSObject.remoteConfigManager.cachedConfig ?? .emptyConfig
    }

    /// Difference between the last time the server says it is and the time our
    /// local device says it is. Add this to the local device time to get the
    /// "real" time according to the server.
    ///
    /// This will always be noisy; for one the server response takes variable
    /// time to get to us, so really this represents the time on the server when
    /// it crafted its response, not when we got it. And of course the local
    /// clock can change.
    fileprivate let lastKnownClockSkew: TimeInterval

    fileprivate let isEnabledFlags: [String: Bool]
    fileprivate let valueFlags: [String: String]
    fileprivate let timeGatedFlags: [String: Date]

    public let paymentsDisabledRegions: PhoneNumberRegions
    public let applePayDisabledRegions: PhoneNumberRegions
    public let creditAndDebitCardDisabledRegions: PhoneNumberRegions
    public let paypalDisabledRegions: PhoneNumberRegions
    public let sepaEnabledRegions: PhoneNumberRegions
    public let idealEnabledRegions: PhoneNumberRegions

    init(
        clockSkew: TimeInterval,
        isEnabledFlags: [String: Bool],
        valueFlags: [String: String],
        timeGatedFlags: [String: Date]
    ) {
        self.lastKnownClockSkew = clockSkew
        self.isEnabledFlags = isEnabledFlags
        self.valueFlags = valueFlags
        self.timeGatedFlags = timeGatedFlags
        self.paymentsDisabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .paymentsDisabledRegions)
        self.applePayDisabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .applePayDisabledRegions)
        self.creditAndDebitCardDisabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .creditAndDebitCardDisabledRegions)
        self.paypalDisabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .paypalDisabledRegions)
        self.sepaEnabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .sepaEnabledRegions)
        self.idealEnabledRegions = Self.parsePhoneNumberRegions(valueFlags: valueFlags, flag: .idealEnabledRegions)
    }

    fileprivate static var emptyConfig: RemoteConfig {
        RemoteConfig(clockSkew: 0, isEnabledFlags: [:], valueFlags: [:], timeGatedFlags: [:])
    }

    fileprivate func mergingHotSwappableFlags(from newConfig: RemoteConfig) -> RemoteConfig {
        var isEnabledFlags = self.isEnabledFlags
        for flag in IsEnabledFlag.allCases {
            guard flag.isHotSwappable else { continue }
            isEnabledFlags[flag.rawValue] = newConfig.isEnabledFlags[flag.rawValue]
        }
        var valueFlags = self.valueFlags
        for flag in ValueFlag.allCases {
            guard flag.isHotSwappable else { continue }
            valueFlags[flag.rawValue] = newConfig.valueFlags[flag.rawValue]
        }
        var timeGatedFlags = self.timeGatedFlags
        for flag in TimeGatedFlag.allCases {
            guard flag.isHotSwappable else { continue }
            timeGatedFlags[flag.rawValue] = newConfig.timeGatedFlags[flag.rawValue]
        }
        return RemoteConfig(
            clockSkew: newConfig.lastKnownClockSkew,
            isEnabledFlags: isEnabledFlags,
            valueFlags: valueFlags,
            timeGatedFlags: timeGatedFlags
        )
    }

    public var groupsV2MaxGroupSizeRecommended: UInt {
        getUIntValue(forFlag: .groupsV2MaxGroupSizeRecommended, defaultValue: 151)
    }

    public var groupsV2MaxGroupSizeHardLimit: UInt {
        getUIntValue(forFlag: .groupsV2MaxGroupSizeHardLimit, defaultValue: 1001)
    }

    public var groupsV2MaxBannedMembers: UInt {
        groupsV2MaxGroupSizeHardLimit
    }

    public var cdsSyncInterval: TimeInterval {
        interval(.cdsSyncInterval, defaultInterval: kDayInterval * 2)
    }

    public var automaticSessionResetKillSwitch: Bool {
        return isEnabled(.automaticSessionResetKillSwitch)
    }

    public var automaticSessionResetAttemptInterval: TimeInterval {
        interval(.automaticSessionResetAttemptInterval, defaultInterval: kHourInterval)
    }

    public var reactiveProfileKeyAttemptInterval: TimeInterval {
        interval(.reactiveProfileKeyAttemptInterval, defaultInterval: kHourInterval)
    }

    public var paymentsResetKillSwitch: Bool {
        isEnabled(.paymentsResetKillSwitch)
    }

    public var canDonateOneTimeWithApplePay: Bool {
        !isEnabled(.applePayOneTimeDonationKillSwitch)
    }

    public var canDonateGiftWithApplePay: Bool {
        !isEnabled(.applePayGiftDonationKillSwitch)
    }

    public var canDonateMonthlyWithApplePay: Bool {
        !isEnabled(.applePayMonthlyDonationKillSwitch)
    }

    public var canDonateOneTimeWithCreditOrDebitCard: Bool {
        !isEnabled(.cardOneTimeDonationKillSwitch)
    }

    public var canDonateGiftWithCreditOrDebitCard: Bool {
        !isEnabled(.cardGiftDonationKillSwitch)
    }

    public var canDonateMonthlyWithCreditOrDebitCard: Bool {
        !isEnabled(.cardMonthlyDonationKillSwitch)
    }

    public var canDonateOneTimeWithPaypal: Bool {
        !isEnabled(.paypalOneTimeDonationKillSwitch)
    }

    public var canDonateGiftWithPayPal: Bool {
        !isEnabled(.paypalGiftDonationKillSwitch)
    }

    public var canDonateMonthlyWithPaypal: Bool {
        !isEnabled(.paypalMonthlyDonationKillSwitch)
    }

    public func standardMediaQualityLevel(localPhoneNumber: String?) -> ImageQualityLevel? {
        let rawValue: String = ValueFlag.standardMediaQualityLevel.rawValue
        guard
            let csvString = valueFlags[rawValue],
            let stringValue = Self.countryCodeValue(csvString: csvString, csvDescription: rawValue, localPhoneNumber: localPhoneNumber),
            let uintValue = UInt(stringValue),
            let defaultMediaQuality = ImageQualityLevel(rawValue: uintValue)
        else {
            return nil
        }
        return defaultMediaQuality
    }

    fileprivate static func parsePhoneNumberRegions(
        valueFlags: [String: String],
        flag: ValueFlag
    ) -> PhoneNumberRegions {
        guard let valueList = valueFlags[flag.rawValue] else { return [] }
        return PhoneNumberRegions(fromRemoteConfig: valueList)
    }

    public var messageResendKillSwitch: Bool {
        isEnabled(.messageResendKillSwitch)
    }

    public var replaceableInteractionExpiration: TimeInterval {
        interval(.replaceableInteractionExpiration, defaultInterval: kHourInterval)
    }

    public var messageSendLogEntryLifetime: TimeInterval {
        interval(.messageSendLogEntryLifetime, defaultInterval: 2 * kWeekInterval)
    }

    public var maxGroupCallRingSize: UInt {
        getUIntValue(forFlag: .maxGroupCallRingSize, defaultValue: 16)
    }

    public var enableAutoAPNSRotation: Bool {
        return isEnabled(.enableAutoAPNSRotation, defaultValue: false)
    }

    /// The minimum length for a valid nickname, in Unicode codepoints.
    public var minNicknameLength: UInt32 {
        getUInt32Value(forFlag: .minNicknameLength, defaultValue: 3)
    }

    /// The maximum length for a valid nickname, in Unicode codepoints.
    public var maxNicknameLength: UInt32 {
        getUInt32Value(forFlag: .maxNicknameLength, defaultValue: 32)
    }

    public var maxAttachmentDownloadSizeBytes: UInt {
        return getUIntValue(forFlag: .maxAttachmentDownloadSizeBytes, defaultValue: 100 * 1024 * 1024)
    }

    // Hardcoded value (but lives alongside `maxAttachmentDownloadSizeBytes`).
    public var maxMediaTierThumbnailDownloadSizeBytes: UInt = 1024 * 8

    public var enableGifSearch: Bool {
        return isEnabled(.enableGifSearch, defaultValue: true)
    }

    public var shouldCheckForServiceExtensionFailures: Bool {
        return !isEnabled(.serviceExtensionFailureKillSwitch)
    }

    public var backgroundRefreshInterval: TimeInterval {
        return TimeInterval(getUIntValue(
            forFlag: .backgroundRefreshInterval,
            defaultValue: UInt(kDayInterval)
        ))
    }

    @available(*, unavailable, message: "cached in UserDefaults by ChatConnectionManager")
    public var experimentalTransportUseLibsignal: Bool {
        return false
    }

    public var experimentalTransportShadowingHigh: Bool {
        return isEnabled(.experimentalTransportShadowingHigh, defaultValue: false)
    }

    @available(*, unavailable, message: "cached in UserDefaults by ChatConnectionManager")
    public var experimentalTransportShadowingEnabled: Bool {
        return false
    }

    public var cdsiLookupWithLibsignal: Bool {
        return isEnabled(.cdsiLookupWithLibsignal, defaultValue: true)
    }

    /// The time a linked device may be offline before it expires and is
    /// unlinked.
    public var linkedDeviceLifespan: TimeInterval {
        return interval(
            .linkedDeviceLifespanInterval,
            defaultInterval: kMonthInterval
        )
    }

    public var callLinkJoin: Bool {
        return (
            FeatureBuild.current == .dev
            || FeatureBuild.current == .internal && isEnabled(.callLinkJoin)
        )
    }

    // MARK: UInt values

    private func getUIntValue(
        forFlag flag: ValueFlag,
        defaultValue: UInt
    ) -> UInt {
        getStringConvertibleValue(
            forFlag: flag,
            defaultValue: defaultValue
        )
    }

    private func getUInt32Value(
        forFlag flag: ValueFlag,
        defaultValue: UInt32
    ) -> UInt32 {
        getStringConvertibleValue(
            forFlag: flag,
            defaultValue: defaultValue
        )
    }

    private func getStringConvertibleValue<V>(
        forFlag flag: ValueFlag,
        defaultValue: V
    ) -> V where V: LosslessStringConvertible {
        guard AppReadinessGlobal.isAppReady else {
            owsFailDebug("Storage is not yet ready.")
            return defaultValue
        }

        guard let stringValue: String = value(flag) else {
            return defaultValue
        }

        guard let value = V(stringValue) else {
            owsFailDebug("Invalid value.")
            return defaultValue
        }

        return value
    }

    // MARK: - Country code buckets

    /// Determine if a country-code-dependent flag is enabled for the current
    /// user, given a country-code CSV and key.
    ///
    /// - Parameter csvString: a CSV containing `<country-code>:<parts-per-million>` pairs
    /// - Parameter key: a key to use as part of bucketing
    static func isCountryCodeBucketEnabled(csvString: String, key: String, csvDescription: String, localIdentifiers: LocalIdentifiers) -> Bool {
        guard
            let countryCodeValue = countryCodeValue(csvString: csvString, csvDescription: csvDescription, localPhoneNumber: localIdentifiers.phoneNumber),
            let countEnabled = UInt64(countryCodeValue)
        else {
            return false
        }

        return isBucketEnabled(key: key, countEnabled: countEnabled, bucketSize: 1_000_000, localAci: localIdentifiers.aci)
    }

    private static func isCountryCodeBucketEnabled(flag: ValueFlag, valueFlags: [String: String], localIdentifiers: LocalIdentifiers) -> Bool {
        let rawValue = flag.rawValue
        guard let csvString = valueFlags[rawValue] else { return false }

        return isCountryCodeBucketEnabled(csvString: csvString, key: rawValue, csvDescription: rawValue, localIdentifiers: localIdentifiers)
    }

    /// Given a CSV of `<country-code>:<value>` pairs, extract the `<value>`
    /// corresponding to the current user's country.
    private static func countryCodeValue(csvString: String, csvDescription: String, localPhoneNumber: String?) -> String? {
        guard !csvString.isEmpty else { return nil }

        // The value should always be a comma-separated list of country codes
        // colon-separated from a value. There all may be an optional be a wildcard
        // "*" country code that any unspecified country codes should use. If
        // neither the local country code or the wildcard is specified, we assume
        // the value is not set.
        let callingCodeToValueMap = csvString
            .components(separatedBy: ",")
            .reduce(into: [String: String]()) { result, value in
                let components = value.components(separatedBy: ":")
                guard components.count == 2 else { return owsFailDebug("Invalid \(csvDescription) value \(value)") }
                let callingCode = components[0]
                let countryValue = components[1]
                result[callingCode] = countryValue
            }

        guard !callingCodeToValueMap.isEmpty else { return nil }

        guard
            let localPhoneNumber,
            let localCallingCode = NSObject.phoneNumberUtil.parseE164(localPhoneNumber)?.getCallingCode()?.stringValue
        else {
            owsFailDebug("Invalid local number")
            return nil
        }

        return callingCodeToValueMap[localCallingCode] ?? callingCodeToValueMap["*"]
    }

    private static func isBucketEnabled(key: String, countEnabled: UInt64, bucketSize: UInt64, localAci: Aci) -> Bool {
        return countEnabled > bucket(key: key, aci: localAci, bucketSize: bucketSize)
    }

    static func bucket(key: String, aci: Aci, bucketSize: UInt64) -> UInt64 {
        guard var data = (key + ".").data(using: .utf8) else {
            owsFailDebug("Failed to get data from key")
            return 0
        }

        data.append(Data(aci.serviceIdBinary))

        let hash = Data(SHA256.hash(data: data))
        guard hash.count == 32 else {
            owsFailDebug("Hash has incorrect length \(hash.count)")
            return 0
        }

        // uuid_bucket = UINT64_FROM_FIRST_8_BYTES_BIG_ENDIAN(SHA256(rawFlag + "." + uuidBytes)) % bucketSize
        return UInt64(bigEndianData: hash.prefix(8))! % bucketSize
    }

    // MARK: -

    private func interval(_ flag: ValueFlag, defaultInterval: TimeInterval) -> TimeInterval {
        guard let intervalString: String = value(flag), let interval = TimeInterval(intervalString) else {
            return defaultInterval
        }
        return interval
    }

    private func isEnabled(_ flag: IsEnabledFlag, defaultValue: Bool = false) -> Bool {
        return isEnabledFlags[flag.rawValue] ?? defaultValue
    }

    private func isEnabled(_ flag: TimeGatedFlag, defaultValue: Bool = false) -> Bool {
        guard let dateThreshold = timeGatedFlags[flag.rawValue] else {
            return defaultValue
        }
        let correctedDate = Date().addingTimeInterval(self.lastKnownClockSkew)
        return correctedDate >= dateThreshold
    }

    private func value(_ flag: ValueFlag) -> String? {
        return valueFlags[flag.rawValue]
    }

    public func debugDescriptions() -> [String: String] {
        var result = [String: String]()
        for (key, value) in isEnabledFlags {
            result[key] = "\(value)"
        }
        for (key, value) in valueFlags {
            result[key] = "\(value)"
        }
        for (key, value) in timeGatedFlags {
            result[key] = "\(value)"
        }
        return result
    }

    public func logFlags() {
        for (key, value) in debugDescriptions() {
            Logger.info("RemoteConfig: \(key) = \(value)")
        }
    }
}

// MARK: - IsEnabledFlag

private enum IsEnabledFlag: String, FlagType {
    case applePayGiftDonationKillSwitch = "ios.applePayGiftDonationKillSwitch"
    case applePayMonthlyDonationKillSwitch = "ios.applePayMonthlyDonationKillSwitch"
    case applePayOneTimeDonationKillSwitch = "ios.applePayOneTimeDonationKillSwitch"
    case automaticSessionResetKillSwitch = "ios.automaticSessionResetKillSwitch"
    case callLinkJoin = "ios.callLink.join.v1"
    case cardGiftDonationKillSwitch = "ios.cardGiftDonationKillSwitch"
    case cardMonthlyDonationKillSwitch = "ios.cardMonthlyDonationKillSwitch"
    case cardOneTimeDonationKillSwitch = "ios.cardOneTimeDonationKillSwitch"
    case cdsiLookupWithLibsignal = "ios.cdsiLookup.libsignal"
    case deleteForMeSyncMessageSending = "ios.deleteForMeSyncMessage.sending"
    case enableAutoAPNSRotation = "ios.enableAutoAPNSRotation"
    case enableGifSearch = "global.gifSearch"
    case experimentalTransportShadowingEnabled = "ios.experimentalTransportEnabled.shadowing"
    case experimentalTransportShadowingHigh = "ios.experimentalTransportEnabled.shadowingHigh"
    case experimentalTransportUseLibsignal = "ios.experimentalTransportEnabled.libsignal"
    case experimentalTransportUseLibsignalAuth = "ios.experimentalTransportEnabled.libsignalAuth"
    case messageResendKillSwitch = "ios.messageResendKillSwitch"
    case paymentsResetKillSwitch = "ios.paymentsResetKillSwitch"
    case paypalGiftDonationKillSwitch = "ios.paypalGiftDonationKillSwitch"
    case paypalMonthlyDonationKillSwitch = "ios.paypalMonthlyDonationKillSwitch"
    case paypalOneTimeDonationKillSwitch = "ios.paypalOneTimeDonationKillSwitch"
    case ringrtcNwPathMonitorTrialKillSwitch = "ios.ringrtcNwPathMonitorTrialKillSwitch"
    case serviceExtensionFailureKillSwitch = "ios.serviceExtensionFailureKillSwitch"

    var isSticky: Bool {
        switch self {
        case .applePayGiftDonationKillSwitch: false
        case .applePayMonthlyDonationKillSwitch: false
        case .applePayOneTimeDonationKillSwitch: false
        case .automaticSessionResetKillSwitch: false
        case .callLinkJoin: false
        case .cardGiftDonationKillSwitch: false
        case .cardMonthlyDonationKillSwitch: false
        case .cardOneTimeDonationKillSwitch: false
        case .cdsiLookupWithLibsignal: false
        case .deleteForMeSyncMessageSending: false
        case .enableAutoAPNSRotation: false
        case .enableGifSearch: false
        case .experimentalTransportShadowingEnabled: false
        case .experimentalTransportShadowingHigh: false
        case .experimentalTransportUseLibsignal: false
        case .experimentalTransportUseLibsignalAuth: false
        case .messageResendKillSwitch: false
        case .paymentsResetKillSwitch: false
        case .paypalGiftDonationKillSwitch: false
        case .paypalMonthlyDonationKillSwitch: false
        case .paypalOneTimeDonationKillSwitch: false
        case .ringrtcNwPathMonitorTrialKillSwitch: false
        case .serviceExtensionFailureKillSwitch: false
        }
    }
    var isHotSwappable: Bool {
        switch self {
        case .applePayGiftDonationKillSwitch: false
        case .applePayMonthlyDonationKillSwitch: false
        case .applePayOneTimeDonationKillSwitch: false
        case .automaticSessionResetKillSwitch: false
        case .callLinkJoin: true
        case .cardGiftDonationKillSwitch: false
        case .cardMonthlyDonationKillSwitch: false
        case .cardOneTimeDonationKillSwitch: false
        case .cdsiLookupWithLibsignal: true
        case .deleteForMeSyncMessageSending: false
        case .enableAutoAPNSRotation: false
        case .enableGifSearch: false
        case .experimentalTransportShadowingEnabled: false
        case .experimentalTransportShadowingHigh: false
        case .experimentalTransportUseLibsignal: false
        case .experimentalTransportUseLibsignalAuth: false
        case .messageResendKillSwitch: false
        case .paymentsResetKillSwitch: false
        case .paypalGiftDonationKillSwitch: false
        case .paypalMonthlyDonationKillSwitch: false
        case .paypalOneTimeDonationKillSwitch: false
        case .ringrtcNwPathMonitorTrialKillSwitch: false
        case .serviceExtensionFailureKillSwitch: true
        }
    }
}

private enum ValueFlag: String, FlagType {
    case applePayDisabledRegions = "global.donations.apayDisabledRegions"
    case automaticSessionResetAttemptInterval = "ios.automaticSessionResetAttemptInterval"
    case backgroundRefreshInterval = "ios.backgroundRefreshInterval"
    case cdsSyncInterval = "cds.syncInterval.seconds"
    case clientExpiration = "ios.clientExpiration"
    case creditAndDebitCardDisabledRegions = "global.donations.ccDisabledRegions"
    case groupsV2MaxGroupSizeHardLimit = "global.groupsv2.groupSizeHardLimit"
    case groupsV2MaxGroupSizeRecommended = "global.groupsv2.maxGroupSize"
    case idealEnabledRegions = "global.donations.idealEnabledRegions"
    case linkedDeviceLifespanInterval = "ios.linkedDeviceLifespanInterval"
    case maxAttachmentDownloadSizeBytes = "global.attachments.maxBytes"
    case maxGroupCallRingSize = "global.calling.maxGroupCallRingSize"
    case maxNicknameLength = "global.nicknames.max"
    case messageSendLogEntryLifetime = "ios.messageSendLogEntryLifetime"
    case minNicknameLength = "global.nicknames.min"
    case paymentsDisabledRegions = "global.payments.disabledRegions"
    case paypalDisabledRegions = "global.donations.paypalDisabledRegions"
    case reactiveProfileKeyAttemptInterval = "ios.reactiveProfileKeyAttemptInterval"
    case replaceableInteractionExpiration = "ios.replaceableInteractionExpiration"
    case sepaEnabledRegions = "global.donations.sepaEnabledRegions"
    case standardMediaQualityLevel = "ios.standardMediaQualityLevel"

    var isSticky: Bool {
        switch self {
        case .applePayDisabledRegions: false
        case .automaticSessionResetAttemptInterval: false
        case .backgroundRefreshInterval: false
        case .cdsSyncInterval: false
        case .clientExpiration: false
        case .creditAndDebitCardDisabledRegions: false
        case .groupsV2MaxGroupSizeHardLimit: true
        case .groupsV2MaxGroupSizeRecommended: true
        case .idealEnabledRegions: false
        case .linkedDeviceLifespanInterval: false
        case .maxAttachmentDownloadSizeBytes: false
        case .maxGroupCallRingSize: false
        case .maxNicknameLength: false
        case .messageSendLogEntryLifetime: false
        case .minNicknameLength: false
        case .paymentsDisabledRegions: false
        case .paypalDisabledRegions: false
        case .reactiveProfileKeyAttemptInterval: false
        case .replaceableInteractionExpiration: false
        case .sepaEnabledRegions: false
        case .standardMediaQualityLevel: false
        }
    }

    var isHotSwappable: Bool {
        switch self {
        case .applePayDisabledRegions: true
        case .automaticSessionResetAttemptInterval: true
        case .backgroundRefreshInterval: true
        case .cdsSyncInterval: false
        case .clientExpiration: false
        case .creditAndDebitCardDisabledRegions: true
        case .groupsV2MaxGroupSizeHardLimit: true
        case .groupsV2MaxGroupSizeRecommended: true
        case .idealEnabledRegions: true
        case .linkedDeviceLifespanInterval: true
        case .maxAttachmentDownloadSizeBytes: false
        case .maxGroupCallRingSize: true
        case .maxNicknameLength: false
        case .messageSendLogEntryLifetime: false
        case .minNicknameLength: false
        case .paymentsDisabledRegions: true
        case .paypalDisabledRegions: true
        case .reactiveProfileKeyAttemptInterval: true
        case .replaceableInteractionExpiration: false
        case .sepaEnabledRegions: true
        case .standardMediaQualityLevel: false
        }
    }
}

private enum TimeGatedFlag: String, FlagType {
    case __none

    var isSticky: Bool {
        switch self {
        case .__none: false
        }
    }

    var isHotSwappable: Bool {
        // These flags are time-gated. This means they are hot-swappable by
        // default. Even if we don't fetch a fresh remote config, we may cross the
        // time threshold while the app is in memory, updating the value from false
        // to true. As such we'll also hot swap every time gated flag.
        return true
    }
}

// MARK: -

private protocol FlagType: CaseIterable {
    // Values defined in this array remain set once they are set regardless of
    // the remote state.
    var isSticky: Bool { get }

    // Values defined in this array will update while the app is running, as
    // soon as we fetch an update to the remote config. They will not wait for
    // an app restart.
    var isHotSwappable: Bool { get }
}

// MARK: -

public protocol RemoteConfigManager {
    func warmCaches()
    var cachedConfig: RemoteConfig? { get }
    func refresh(account: AuthedAccount) -> Promise<RemoteConfig>
}

// MARK: -

#if TESTABLE_BUILD

public class StubbableRemoteConfigManager: RemoteConfigManager {
    public var cachedConfig: RemoteConfig?

    public func warmCaches() {}

    public func refresh(account: AuthedAccount) -> Promise<RemoteConfig> {
        return .value(cachedConfig!)
    }
}

#endif

// MARK: -

public class RemoteConfigManagerImpl: RemoteConfigManager {
    private let appExpiry: AppExpiry
    private let appReadiness: AppReadiness
    private let db: DB
    private let keyValueStore: KeyValueStore
    private let tsAccountManager: TSAccountManager
    private let serviceClient: SignalServiceClient

    // MARK: -

    private let _cachedConfig = AtomicValue<RemoteConfig?>(nil, lock: .init())
    public var cachedConfig: RemoteConfig? {
        let result = _cachedConfig.get()
        owsAssertDebug(result != nil, "cachedConfig not yet set.")
        return result
    }
    @discardableResult
    private func updateCachedConfig(_ updateBlock: (RemoteConfig?) -> RemoteConfig) -> RemoteConfig {
        return _cachedConfig.update { mutableValue in
            let newValue = updateBlock(mutableValue)
            mutableValue = newValue
            return newValue
        }
    }

    public init(
        appExpiry: AppExpiry,
        appReadiness: AppReadiness,
        db: DB,
        keyValueStoreFactory: KeyValueStoreFactory,
        tsAccountManager: TSAccountManager,
        serviceClient: SignalServiceClient
    ) {
        self.appExpiry = appExpiry
        self.appReadiness = appReadiness
        self.db = db
        self.keyValueStore = keyValueStoreFactory.keyValueStore(collection: "RemoteConfigManager")
        self.tsAccountManager = tsAccountManager
        self.serviceClient = serviceClient

        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync {
            guard self.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                return
            }
            self.scheduleNextRefresh()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )
    }

    // MARK: -

    @objc
    private func registrationStateDidChange() {
        AssertIsOnMainThread()

        guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else { return }
        Logger.info("Refreshing and immediately applying new flags due to new registration.")
        refresh().catch { error in
            Logger.error("Failed to update remote config after registration change \(error)")
        }
    }

    public func warmCaches() {
        owsAssertDebug(GRDBSchemaMigrator.areMigrationsComplete)

        // swiftlint:disable large_tuple
        let (
            lastKnownClockSkew,
            isEnabledFlags,
            valueFlags,
            timeGatedFlags,
            registrationState
        ): (TimeInterval, [String: Bool]?, [String: String]?, [String: Date]?, TSRegistrationState) = db.read { tx in
            return (
                self.keyValueStore.getLastKnownClockSkew(transaction: tx),
                self.keyValueStore.getRemoteConfigIsEnabledFlags(transaction: tx),
                self.keyValueStore.getRemoteConfigValueFlags(transaction: tx),
                self.keyValueStore.getRemoteConfigTimeGatedFlags(transaction: tx),
                DependenciesBridge.shared.tsAccountManager.registrationState(tx: tx)
            )
        }
        // swiftlint:enable large_tuple
        let remoteConfig: RemoteConfig
        if registrationState.isRegistered, (isEnabledFlags != nil || valueFlags != nil || timeGatedFlags != nil) {
            remoteConfig = RemoteConfig(
                clockSkew: lastKnownClockSkew,
                isEnabledFlags: isEnabledFlags ?? [:],
                valueFlags: valueFlags ?? [:],
                timeGatedFlags: timeGatedFlags ?? [:]
            )
        } else {
            // If we're not registered or haven't saved one, use an empty one.
            remoteConfig = .emptyConfig
        }
        updateCachedConfig { _ in remoteConfig }
        warmSecondaryCaches(valueFlags: valueFlags ?? [:])

        appReadiness.runNowOrWhenAppWillBecomeReady {
            RemoteConfig.current.logFlags()
        }
    }

    fileprivate func warmSecondaryCaches(valueFlags: [String: String]) {
        checkClientExpiration(valueFlags: valueFlags)
    }

    private static let refreshInterval = 2 * kHourInterval
    private var refreshTimer: Timer?

    private var lastAttempt: Date = .distantPast
    private var consecutiveFailures: UInt = 0
    private var nextPermittedAttempt: Date {
        AssertIsOnMainThread()
        let backoffDelay = OWSOperation.retryIntervalForExponentialBackoff(failureCount: consecutiveFailures)
        let earliestPermittedAttempt = lastAttempt.addingTimeInterval(backoffDelay)

        let lastSuccess = db.read { keyValueStore.getLastFetched(transaction: $0) }
        let nextScheduledRefresh = (lastSuccess ?? .distantPast).addingTimeInterval(Self.refreshInterval)

        return max(earliestPermittedAttempt, nextScheduledRefresh)
    }

    private func scheduleNextRefresh() {
        AssertIsOnMainThread()
        refreshTimer?.invalidate()
        refreshTimer = nil
        let nextAttempt = nextPermittedAttempt

        if nextAttempt.isBeforeNow {
            refresh()
        } else {
            Logger.info("Scheduling remote config refresh for \(nextAttempt).")
            refreshTimer = Timer.scheduledTimer(
                withTimeInterval: nextAttempt.timeIntervalSinceNow,
                repeats: false
            ) { [weak self] timer in
                timer.invalidate()
                self?.refresh()
            }
        }
    }

    @discardableResult
    public func refresh(account: AuthedAccount = .implicit()) -> Promise<RemoteConfig> {
        AssertIsOnMainThread()
        lastAttempt = Date()

        let promise = firstly(on: DispatchQueue.global()) {
            self.serviceClient.getRemoteConfig(auth: account.chatServiceAuth)
        }.map(on: DispatchQueue.global()) { (fetchedConfig: RemoteConfigResponse) in

            let clockSkew: TimeInterval
            if let serverEpochTimeSeconds = fetchedConfig.serverEpochTimeSeconds {
                let dateAccordingToServer = Date(timeIntervalSince1970: TimeInterval(serverEpochTimeSeconds))
                clockSkew = dateAccordingToServer.timeIntervalSince(Date())
            } else {
                clockSkew = 0
            }

            // We filter the received config down to just the supported flags. This
            // ensures if we have a sticky flag, it doesn't get inadvertently set
            // because we cached a value before it went public. e.g. if we set a sticky
            // flag to 100% in beta then turn it back to 0% before going to production.
            var isEnabledFlags = [String: Bool]()
            var valueFlags = [String: String]()
            var timeGatedFlags = [String: Date]()
            fetchedConfig.items.forEach { (key: String, item: RemoteConfigItem) in
                switch item {
                case .isEnabled(let isEnabled):
                    if IsEnabledFlag(rawValue: key) != nil {
                        isEnabledFlags[key] = isEnabled
                    }
                case .value(let value):
                    if ValueFlag(rawValue: key) != nil {
                        valueFlags[key] = value
                    } else if TimeGatedFlag(rawValue: key) != nil {
                        if let secondsSinceEpoch = TimeInterval(value) {
                            timeGatedFlags[key] = Date(timeIntervalSince1970: secondsSinceEpoch)
                        } else {
                            owsFailDebug("Invalid value: \(value) \(type(of: value))")
                        }
                    }
                }
            }

            // Persist all flags in the database to be applied on next launch.

            self.db.write { transaction in
                // Preserve any sticky flags.
                if let existingConfig = self.keyValueStore.getRemoteConfigIsEnabledFlags(transaction: transaction) {
                    existingConfig.forEach { (key: String, value: Bool) in
                        // Preserve "is enabled" flags if they are sticky and already set.
                        if let flag = IsEnabledFlag(rawValue: key), flag.isSticky, value == true {
                            isEnabledFlags[key] = value
                        }
                    }
                }
                if let existingConfig = self.keyValueStore.getRemoteConfigValueFlags(transaction: transaction) {
                    existingConfig.forEach { (key: String, value: String) in
                        // Preserve "value" flags if they are sticky and already set and missing
                        // from the fetched config.
                        if let flag = ValueFlag(rawValue: key), flag.isSticky, valueFlags[key] == nil {
                            valueFlags[key] = value
                        }
                    }
                }
                if let existingConfig = self.keyValueStore.getRemoteConfigTimeGatedFlags(transaction: transaction) {
                    existingConfig.forEach { (key: String, value: Date) in
                        // Preserve "time gated" flags if they are sticky and already set and
                        // missing from the fetched config.
                        if let flag = TimeGatedFlag(rawValue: key), flag.isSticky, timeGatedFlags[key] == nil {
                            timeGatedFlags[key] = value
                        }
                    }
                }

                self.keyValueStore.setClockSkew(clockSkew, transaction: transaction)
                self.keyValueStore.setRemoteConfigIsEnabledFlags(isEnabledFlags, transaction: transaction)
                self.keyValueStore.setRemoteConfigValueFlags(valueFlags, transaction: transaction)
                self.keyValueStore.setRemoteConfigTimeGatedFlags(timeGatedFlags, transaction: transaction)
                self.keyValueStore.setLastFetched(Date(), transaction: transaction)

                self.checkClientExpiration(valueFlags: valueFlags)
            }

            // As a special case, persist RingRTC field trials. See comments in
            // ``RingrtcFieldTrials`` for details.
            RingrtcFieldTrials.saveNwPathMonitorTrialState(
                isEnabled: {
                    let flag = IsEnabledFlag.ringrtcNwPathMonitorTrialKillSwitch
                    let isKilled = isEnabledFlags[flag.rawValue] ?? false
                    return !isKilled
                }(),
                in: CurrentAppContext().appUserDefaults()
            )
            // Similarly, persist the choice of libsignal for the chat websockets.
            let shouldUseLibsignalForIdentifiedWebsocket = isEnabledFlags[IsEnabledFlag.experimentalTransportUseLibsignalAuth.rawValue] ?? false
            ChatConnectionManagerImpl.saveShouldUseLibsignalForIdentifiedWebsocket(
                shouldUseLibsignalForIdentifiedWebsocket,
                in: CurrentAppContext().appUserDefaults()
            )
            let shouldUseLibsignalForUnidentifiedWebsocket = isEnabledFlags[IsEnabledFlag.experimentalTransportUseLibsignal.rawValue] ?? false
            ChatConnectionManagerImpl.saveShouldUseLibsignalForUnidentifiedWebsocket(
                shouldUseLibsignalForUnidentifiedWebsocket,
                in: CurrentAppContext().appUserDefaults()
            )
            let enableShadowingForUnidentifiedWebsocket = isEnabledFlags[IsEnabledFlag.experimentalTransportShadowingEnabled.rawValue] ?? true
            ChatConnectionManagerImpl.saveEnableShadowingForUnidentifiedWebsocket(
                enableShadowingForUnidentifiedWebsocket,
                in: CurrentAppContext().appUserDefaults()
            )

            self.consecutiveFailures = 0

            // This has *all* the new values, even those that can't be hot-swapped.
            let newConfig = RemoteConfig(
                clockSkew: clockSkew,
                isEnabledFlags: isEnabledFlags,
                valueFlags: valueFlags,
                timeGatedFlags: timeGatedFlags
            )

            // This has hot-swappable new values and non-hot-swappable old values.
            let mergedConfig = self.updateCachedConfig { oldConfig in
                return (oldConfig ?? .emptyConfig).mergingHotSwappableFlags(from: newConfig)
            }
            self.warmSecondaryCaches(valueFlags: mergedConfig.valueFlags)

            // We always return `newConfig` because callers may want to see the
            // newly-fetched, non-hot-swappable values for themselves.
            return newConfig
        }

        promise.catch(on: DispatchQueue.main) { error in
            Logger.error("error: \(error)")
            self.consecutiveFailures += 1
        }.ensure(on: DispatchQueue.main) {
            self.scheduleNextRefresh()
        }.cauterize()

        return promise
    }

    // MARK: - Client Expiration

    private struct MinimumVersion: Decodable, CustomDebugStringConvertible {
        let mustBeAtLeastVersion: AppVersionNumber4
        let enforcementDate: Date

        enum CodingKeys: String, CodingKey {
            case mustBeAtLeastVersion = "minVersion"
            case enforcementDate = "iso8601"
        }

        var debugDescription: String {
            return "<MinimumVersion \(mustBeAtLeastVersion) @ \(enforcementDate)>"
        }
    }

    private func checkClientExpiration(valueFlags: [String: String]) {
        if let minimumVersions = parseClientExpiration(valueFlags: valueFlags) {
            appExpiry.setExpirationDateForCurrentVersion(remoteExpirationDate(from: minimumVersions), db: db)
        } else {
            // If it's not valid, there's a typo in the config, err on the safe side
            // and leave it alone.
        }
    }

    private func parseClientExpiration(valueFlags: [String: String]) -> [MinimumVersion]? {
        let valueFlag = valueFlags[ValueFlag.clientExpiration.rawValue]
        guard let valueFlag, let dataValue = valueFlag.nilIfEmpty?.data(using: .utf8) else {
            return []
        }

        do {
            let jsonDecoder = JSONDecoder()
            jsonDecoder.dateDecodingStrategy = .iso8601
            return try jsonDecoder.decode([MinimumVersion].self, from: dataValue)
        } catch {
            owsFailDebug("Failed to decode client expiration (\(valueFlag), \(error)), ignoring.")
            return nil
        }
    }

    private func remoteExpirationDate(from minimumVersions: [MinimumVersion]) -> Date? {
        let currentVersion = AppVersionImpl.shared.currentAppVersion4
        // We only consider the requirements we don't already satisfy.
        return minimumVersions.lazy
            .filter { currentVersion < $0.mustBeAtLeastVersion }.map { $0.enforcementDate }.min()
    }
}

// MARK: -

private extension KeyValueStore {

    // MARK: - Remote Config Enabled Flags

    private static var remoteConfigIsEnabledFlagsKey: String { "remoteConfigKey" }

    func getRemoteConfigIsEnabledFlags(transaction: DBReadTransaction) -> [String: Bool]? {
        guard let object = getObject(forKey: Self.remoteConfigIsEnabledFlagsKey,
                                     transaction: transaction) else {
            return nil
        }

        guard let remoteConfig = object as? [String: Bool] else {
            owsFailDebug("unexpected object: \(object)")
            return nil
        }

        return remoteConfig
    }

    func setRemoteConfigIsEnabledFlags(_ newValue: [String: Bool], transaction: DBWriteTransaction) {
        return setObject(newValue,
                         key: Self.remoteConfigIsEnabledFlagsKey,
                         transaction: transaction)
    }

    // MARK: - Remote Config Value Flags

    private static var remoteConfigValueFlagsKey: String { "remoteConfigValueFlags" }

    func getRemoteConfigValueFlags(transaction: DBReadTransaction) -> [String: String]? {
        guard let object = getObject(forKey: Self.remoteConfigValueFlagsKey, transaction: transaction) else {
            return nil
        }

        guard let remoteConfig = object as? [String: String] else {
            owsFailDebug("unexpected object: \(object)")
            return nil
        }

        return remoteConfig
    }

    func setRemoteConfigValueFlags(_ newValue: [String: String], transaction: DBWriteTransaction) {
        return setObject(newValue, key: Self.remoteConfigValueFlagsKey, transaction: transaction)
    }

    // MARK: - Remote Config Time Gated Flags

    private static var remoteConfigTimeGatedFlagsKey: String { "remoteConfigTimeGatedFlags" }

    func getRemoteConfigTimeGatedFlags(transaction: DBReadTransaction) -> [String: Date]? {
        guard let object = getObject(forKey: Self.remoteConfigTimeGatedFlagsKey, transaction: transaction) else {
            return nil
        }

        guard let remoteConfig = object as? [String: Date] else {
            owsFailDebug("unexpected object: \(object)")
            return nil
        }

        return remoteConfig
    }

    func setRemoteConfigTimeGatedFlags(_ newValue: [String: Date], transaction: DBWriteTransaction) {
        return setObject(newValue, key: Self.remoteConfigTimeGatedFlagsKey, transaction: transaction)
    }

    // MARK: - Last Fetched

    var lastFetchedKey: String { "lastFetchedKey" }

    func getLastFetched(transaction: DBReadTransaction) -> Date? {
        return getDate(lastFetchedKey, transaction: transaction)
    }

    func setLastFetched(_ newValue: Date, transaction: DBWriteTransaction) {
        return setDate(newValue, key: lastFetchedKey, transaction: transaction)
    }

    // MARK: - Clock Skew

    var clockSkewKey: String { "clockSkewKey" }

    func getLastKnownClockSkew(transaction: DBReadTransaction) -> TimeInterval {
        return getDouble(clockSkewKey, defaultValue: 0, transaction: transaction)
    }

    func setClockSkew(_ newValue: TimeInterval, transaction: DBWriteTransaction) {
        return setDouble(newValue, key: clockSkewKey, transaction: transaction)
    }
}
