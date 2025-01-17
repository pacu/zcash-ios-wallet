//
//  ShieldFlow.swift
//  ECC-Wallet
//
//  Created by Francisco Gindre on 1/27/21.
//  Copyright © 2021 Francisco Gindre. All rights reserved.
//

import Foundation
import Combine
import SwiftUI
import ZcashLightClientKit

protocol ShieldingPowers {
    var status: CurrentValueSubject<ShieldFlow.Status,Error> { get set }
    func shield() async
}

final class ShieldFlow: ShieldingPowers {
    enum ShieldErrors: Error {
        /**
         Thrown when a shield flow is requested but there's one already in progress
         */
        case shieldFlowAlreadyStarted
    }

    enum Status {
        case notStarted
        case shielding
        case ended(shieldingTx: PendingTransactionEntity)
        case notNeeded
    }
    
    var status: CurrentValueSubject<ShieldFlow.Status, Error>
    var shielder: AutoShielder
    var cancellables = [AnyCancellable]()
    private var synchronizer: CombineSynchronizer = ZECCWalletEnvironment.shared.synchronizer
    
    private init() {
        self.status = CurrentValueSubject<Status,Error>(.notStarted)
        self.shielder = AutoShieldingBuilder.manualShielder(keyProvider: DefaultShieldingKeyProvider(), shielder: synchronizer.synchronizer)
    }
    
    private static var _currentFlow: ShieldingPowers?
    
    static func startWithShilderOrFail(_ shielder: AutoShielder) throws -> ShieldingPowers {
        guard _currentFlow == nil else {
            throw ShieldErrors.shieldFlowAlreadyStarted
        }
        
        let f = Self.current as! ShieldFlow
        f.shielder = shielder
        
        return f
    }
    
    static var current: ShieldingPowers {
        guard let flow = _currentFlow else {
            let f = ShieldFlow()
            _currentFlow = f
            return f
        }
        
        return flow
    }
    
    static func endFlow() {
        _currentFlow = nil
    }
    
    func shield() async {
        self.status.send(.shielding)
        do {
            _ = try await SaplingParameterDownloader.downloadParamsIfnotPresent(
                spendURL: try URL.spendParamsURL(),
                outputURL: try URL.outputParamsURL()
            )


            switch try await self.shielder.shield() {
            case .shielded(let pendingTx):
                logger.debug("shielded \(pendingTx)")
                self.status.send(.ended(shieldingTx: pendingTx))

                break
            case .notNeeded:
                logger.warn(" -- WARNING -- You shielded funds but the result was not needed. This is probably a programming error")
                self.status.send(completion: .finished)
            }

            self.status.send(completion: .finished)
        } catch {
            logger.error("failed to shield funds \(error.localizedDescription)")
            tracker.report(handledException: DeveloperFacingErrors.handledException(error: error))
            self.status.send(completion: .failure(error))
        }
    }
}

fileprivate struct ShieldFlowEnvironmentKey: EnvironmentKey {
    static let defaultValue: ShieldingPowers = ShieldFlow.current
}
extension View {
    func shieldFlowEnvironment(_ env: ShieldingPowers) -> some View {
        environment(\.shieldFlowEnvironment, env)
    }
}
extension EnvironmentValues {
    var shieldFlowEnvironment: ShieldingPowers  {
        get {
            self[ShieldFlowEnvironmentKey.self]
        }
        set {
            self[ShieldFlowEnvironmentKey.self] = newValue
        }
    }
}



//final class MockFailingShieldFlow: ShieldingPowers {
//    
//    var status: CurrentValueSubject<ShieldFlow.Status, Error> = CurrentValueSubject(ShieldFlow.Status.notStarted)
//    
//    func shield() {
//        status.send(.shielding)
//        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
//            self?.status.send(completion: .failure(SynchronizerError.generalError(message: "Could Not Shield Funds")))
//        }
//    }
//}

//final class MockSuccessShieldFlow: ShieldingPowers {
//    var status: CurrentValueSubject<ShieldFlow.Status, Error> = CurrentValueSubject(ShieldFlow.Status.notStarted)
//
//    func shield() {
//        status.send(.shielding)
//        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
//            self?.status.send(.ended)
//        }
//    }
//}
