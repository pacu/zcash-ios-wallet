//
//  ZECCWalletEnvironment.swift
//  wallet
//
//  Created by Francisco Gindre on 1/23/20.
//  Copyright © 2020 Francisco Gindre. All rights reserved.
//

import Foundation
import SwiftUI
import ZcashLightClientKit
import Combine
enum WalletState {
    case uninitialized
    case unprepared
    case initalized
    case syncing
    case synced
    case failure(error: Error)
}


final class ZECCWalletEnvironment: ObservableObject {
    static let autoShieldingThresholdInZatoshi: Int64 = Int64(ZcashSDK.zatoshiPerZEC / 100)
    static let genericErrorMessage = "An error ocurred, please check your device logs"
    static var shared: ZECCWalletEnvironment = try! ZECCWalletEnvironment() // app can't live without this existing.
    static let memoLengthLimit: Int = 512
    
    @Published var state: WalletState
    
    let endpoint = LightWalletEndpoint(
        address: ZcashSDK.isMainnet ? "lightwalletd.electriccoin.co" : "lightwalletd.testnet.electriccoin.co",
        port: 9067,
        secure: true,
        streamingCallTimeoutInMillis: 10 * 60 * 60 * 1000 // ten hours
    )

    var dataDbURL: URL
    var fsBlockDbRoot: URL
    var pendingDbURL: URL
    var outputParamsURL: URL
    var spendParamsURL: URL
    var synchronizer: CombineSynchronizer!
    var autoShielder: AutoShielder!
    var cancellables = [AnyCancellable]()
    var shouldShowAutoShieldingNotice: Bool {
        shouldShowAutoShieldingNoticeScreen()
    }

    #if ENABLE_LOGGING
    var shouldShowFeedbackDialog: Bool { shouldShowFeedbackRequest() }
    #endif
    
    
    static func getInitialState() -> WalletState {
        
        do {
            // are there any keys?
            let keysPresent = SeedManager.default.keysPresent
        
            let dbFilesPresent = try dbFilesPresent()
            
            switch (keysPresent,dbFilesPresent) {
            case (false, false):
                return .uninitialized
            case (false, true):
                return .failure(error: WalletError.initializationFailed(message: "This wallet has Db Files but no keys."))
            case (true, false):
                return .unprepared
            case (true, true):
                return .initalized
            }
        } catch {
            tracker.track(.error(severity: .critical), properties: [
                            ErrorSeverity.underlyingError : "error",
                            ErrorSeverity.messageKey : "exception thrown when getting initial state"
            ])
            return .failure(error: error)
        }
    }
    
    static func dbFilesPresent() throws -> Bool  {
        do {
            let fileManager = FileManager()
            
            let dataDbURL = try URL.dataDbURL()
            let attrs = try fileManager.attributesOfItem(atPath: dataDbURL.path)
            return attrs.count > 0 ? true : false
        } catch  CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile  {
            return false
        } catch {
            throw error
        }
        
    }
    
    private init() throws {
        self.dataDbURL = try URL.dataDbURL()
        self.fsBlockDbRoot = try URL.fsBlockDbRoot()
        self.pendingDbURL = try URL.pendingDbURL()
        self.outputParamsURL = try URL.outputParamsURL()
        self.spendParamsURL = try  URL.spendParamsURL()
        self.state = .unprepared
    }
    
    // Warning: Use with care
    func reset() throws {
        self.synchronizer.stop()
        self.state = Self.getInitialState()
        self.synchronizer = nil
    }
    
    func createNewWallet() async throws {
        
        do {
            let randomPhrase = try MnemonicSeedProvider.default.randomMnemonic()
            
            let birthday = BlockHeight.ofLatestCheckpoint(network: ZCASH_NETWORK)
            
            try SeedManager.default.importBirthday(birthday)
            try SeedManager.default.importPhrase(bip39: randomPhrase)
            try await self.initialize()
        
        } catch {
            throw WalletError.createFailed(underlying: error)
        }
    }
    
    func initialize() async throws {
        let seedPhrase = try SeedManager.default.exportPhrase()
        let seedBytes = try MnemonicSeedProvider.default.toSeed(mnemonic: seedPhrase)
        let viewingKey = try DerivationTool(networkType: ZCASH_NETWORK.networkType)
            .deriveUnifiedSpendingKey(seed: seedBytes, accountIndex: 0)
            .deriveFullViewingKey()

        try self.fixPendingDbName()

        let initializer = Initializer(
            fsBlockDbRoot: self.fsBlockDbRoot,
            dataDbURL: self.dataDbURL,
            pendingDbURL: self.pendingDbURL,
            endpoint: endpoint,
            network: ZCASH_NETWORK,
            spendParamsURL: self.spendParamsURL,
            outputParamsURL: self.outputParamsURL,
            viewingKeys: [viewingKey],
            walletBirthday: try SeedManager.default.exportBirthday(),
            loggerProxy: logger)

        self.synchronizer = try CombineSynchronizer(initializer: initializer)

        self.autoShielder = AutoShieldingBuilder.thresholdAutoShielder(
            keyProvider: DefaultShieldingKeyProvider(),
            shielder: self.synchronizer.synchronizer,
            threshold: Self.autoShieldingThresholdInZatoshi,
            balanceProviding: self.synchronizer)
        try await self.synchronizer.prepare(with: seedBytes)
        
        self.subscribeToApplicationNotificationsPublishers()
        
        try await MainActor.run {
            try self.synchronizer.start()
        }
    }
    
    /**
     only for internal use
     */
    func nuke(abortApplication: Bool = false) {
        Task { @MainActor in
            do {
                SeedManager.default.nukeWallet()
                try await synchronizer.synchronizer.wipe()

                if abortApplication {
                    abort()
                }
            }
            catch {
                logger.error("could not nuke wallet: \(error)")
            }
        }
    }
    
    /**
     Deletes the wallet's files but keeps the user's keys
     */
    func wipe(abortApplication: Bool = true) throws {
        Task { @MainActor in
            try await synchronizer.synchronizer.wipe()
            if abortApplication {
                abort()
            }
        }
    }
    
    static func mapError(error: Error) -> WalletError {
        if let walletError = error as? WalletError {
            return walletError
        } else if let synchronizerError = error as? SynchronizerError {
            switch synchronizerError {
            case .lightwalletdValidationFailed(let underlyingError):
                return WalletError.criticalError(error: underlyingError)
            case .notPrepared:
                return WalletError.initializationFailed(message: "attempt to initialize an unprepared synchronizer")
            case .generalError(let message):
                return WalletError.genericErrorWithMessage(message: message)
            case .initFailed(let message):
                return WalletError.initializationFailed(message: "Synchronizer failed to initialize: \(message)")
            case .syncFailed:
                return WalletError.synchronizerFailed
            case .connectionFailed(let error):
                return WalletError.connectionFailedWithError(error: error)
            case .maxRetryAttemptsReached(attempts: let attempts):
                return WalletError.maxRetriesReached(attempts: attempts)
            case .connectionError:
              return WalletError.connectionFailed
            case .networkTimeout:
                return WalletError.networkTimeout
            case .uncategorized(let underlyingError):
                return WalletError.genericErrorWithError(error: underlyingError)
            case .criticalError:
                return WalletError.criticalError(error: synchronizerError)
            case .parameterMissing(let underlyingError):
                return WalletError.sendFailed(error: underlyingError)
            case .rewindError(let underlyingError):
                return WalletError.genericErrorWithError(error: underlyingError)
            case .rewindErrorUnknownArchorHeight:
                return WalletError.genericErrorWithMessage(message: "unable to rescan to specified height")
            case .invalidAccount:
                return WalletError.genericErrorWithMessage(message: "your wallet asked a balance for an account index that is not derived. This is probably a programming mistake.")
            case .wipeAttemptWhileProcessing:
                return WalletError.genericErrorWithMessage(message: synchronizerError.localizedDescription)
            }
        }
        
        return WalletError.genericErrorWithError(error: error)
    }
    deinit {
        cancellables.forEach {
            c in
            c.cancel()
        }
    }
    
    
    // Mark: handle background activity
    
    var appCycleCancellables = [AnyCancellable]()
    
    var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    
    private var isBackgroundAllowed: Bool {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return true
        default:
            return false
        }
    }
    
    private var isSubscribedToAppDelegateEvents = false
    private var shouldRetryRestart = false
    private func registerBackgroundActivity() {
        if self.taskIdentifier == .invalid {
            self.taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ZcashLightClientKit.SDKSynchronizer", expirationHandler: { [weak self, weak logger] in
                logger?.info("BackgroundTask Expiration Handler Called")
                guard let self = self else { return }
                self.synchronizer.stop()
                self.shouldRetryRestart = true
                self.invalidateBackgroundActivity()
            })
        }
    }
    
    private func invalidateBackgroundActivity() {
        guard self.taskIdentifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(self.taskIdentifier)
        self.taskIdentifier = .invalid
    }
    
    func subscribeToApplicationNotificationsPublishers() {
        self.isSubscribedToAppDelegateEvents = true
        let center = NotificationCenter.default
        
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .subscribe(on: DispatchQueue.main)
            .sink { [weak self, weak logger] _ in
                
                logger?.debug("applicationWillEnterForeground")
                guard let self = self else { return }
                
                self.invalidateBackgroundActivity()
                do {
                    try self.synchronizer.start(retry: self.shouldRetryRestart)
                    self.shouldRetryRestart = false
                } catch {
                    logger?.debug("applicationWillEnterForeground --> Error restarting: \(error)")
                }
                
                
            }
            .store(in: &appCycleCancellables)
        
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .subscribe(on: DispatchQueue.main)
            .sink { [weak logger] _ in
                logger?.debug("didBecomeActiveNotification")
            }
            .store(in: &appCycleCancellables)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .subscribe(on: DispatchQueue.main)
            .sink { [weak self, weak logger] _ in
                self?.registerBackgroundActivity()
                logger?.debug("didEnterBackgroundNotification")
            }
            .store(in: &appCycleCancellables)
        center.publisher(for: UIApplication.willResignActiveNotification)
            .subscribe(on: DispatchQueue.main)
            .sink { [weak logger] _ in
               
                logger?.debug("applicationWillResignActive")
            }
            .store(in: &appCycleCancellables)
        
        center.publisher(for: UIApplication.willTerminateNotification)
            .subscribe(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.synchronizer.stop()
            }
            .store(in: &appCycleCancellables)
        
    }
    
    func unsubscribeFromApplicationNotificationsPublishers() {
        self.isSubscribedToAppDelegateEvents = false
        self.appCycleCancellables.forEach { $0.cancel() }
    }
}

extension ZECCWalletEnvironment {
    
    static var appName: String {
        if ZcashSDK.isMainnet {
            return "ECC Wallet".localized()
        } else {
            return "ECC Testnet"
        }
    }
    
    static var appBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
    
    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    
    func isValidShieldedAddress(_ address: String) -> Bool {
        address.isValidShieldedAddress
    }
    
    func isValidTransparentAddress(_ address: String) -> Bool {
        address.isValidTransparentAddress
    }
    
    func isValidAddress(_ address: String) -> Bool {
        address.isValidAddress
    }
    func sufficientFundsToSend(amount: Double) -> Bool {
        return sufficientFunds(availableBalance: getShieldedBalance(), zatoshiToSend: amount.toZatoshi())
    }
    
    private func sufficientFunds(availableBalance: Int64, zatoshiToSend: Int64) -> Bool {
        availableBalance - zatoshiToSend  - Int64(ZCASH_NETWORK.constants.defaultFee().amount) >= 0
    }
    
    static var minerFee: Double {
        ZCASH_NETWORK.constants.defaultFee().decimalValue.doubleValue
    }
    
    func credentialsAlreadyPresent() -> Bool {
        (try? SeedManager.default.exportPhrase()) != nil
    }
    
    func getShieldedVerifiedBalance() -> Int64 {
        self.synchronizer.initializer.getVerifiedBalance().amount
    }
    
    func getShieldedBalance() -> Int64 {
        self.synchronizer.initializer.getBalance().amount
    }
    
    func getShieldedAddress() async -> UnifiedAddress? {
        await self.synchronizer.synchronizer.getUnifiedAddress(accountIndex: 0)
    }
}


fileprivate struct WalletEnvironmentKey: EnvironmentKey {
    static let defaultValue: ZECCWalletEnvironment = ZECCWalletEnvironment.shared
}

extension EnvironmentValues {
    var walletEnvironment: ZECCWalletEnvironment  {
        get {
            self[WalletEnvironmentKey.self]
        }
        set {
            self[WalletEnvironmentKey.self] = newValue
        }
    }
}

extension View {
    func walletEnvironment(_ env: ZECCWalletEnvironment) -> some View {
        environment(\.walletEnvironment, env)
    }
}

extension ZECCWalletEnvironment {
    func shouldShowAutoShieldingNoticeScreen() -> Bool {
        return !UserSettings.shared.didShowAutoShieldingNotice
    }
    
    func registerAutoShieldingNoticeScreenShown() {
        UserSettings.shared.didShowAutoShieldingNotice = true
    }
}

#if ENABLE_LOGGING
extension ZECCWalletEnvironment {
    func shouldShowFeedbackRequest() -> Bool {
        
        guard let lastDate = UserSettings.shared.lastFeedbackDisplayedOnDate else {
            return true
        }
        let now = Date()
        
        let calendar = Calendar.current
        
        return (calendar.dateComponents([.day], from: lastDate, to: now).day ?? 0) > 1
        
    }
    
    func registerFeedbackSolicitation(on date: Date) {
        UserSettings.shared.lastFeedbackDisplayedOnDate = date
    }
}
#endif


extension ZcashSDK {
    static var isMainnet: Bool {
        switch ZCASH_NETWORK.networkType {
        case .mainnet:
            return true
        case .testnet:
            return false
        }
    }
}


extension ZECCWalletEnvironment {
    func fixPendingDbName() throws {
        do {
            if FileManager.default.isReadableFile(atPath: try URL.wrongPendingDbURL().path) && !FileManager.default.isReadableFile(atPath: pendingDbURL.path) {
                try FileManager.default.moveItem(at: URL.wrongPendingDbURL(), to: pendingDbURL)
            }
        } catch {
            logger.error("fixPendingDbName failed with error \(error)")
            throw error
        }
    }
}
