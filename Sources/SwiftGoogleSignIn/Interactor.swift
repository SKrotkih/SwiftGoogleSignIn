//
//  Interactor.swift
//  SwiftGoogleSignIn
//
//  Created by Serhii Krotkykh
//

import Foundation
import GoogleSignIn
import Combine

enum SignInError: Error {
    case signInError(Error)
    case userIsUndefined
    case permissionsError
    case failedUserData

    func localizedString() -> String {
        switch self {
        case .signInError:
            return "The user has not signed in before or he has since signed out"
        case .userIsUndefined:
            return "The user has not signed in before or he has since signed out"
        case .permissionsError:
            return "Please add scopes to have ability to manage your YouTube videos. The app will not work properly"
        case .failedUserData:
            return "User data is wrong. Please try again later"
        }
    }
}

public class Interactor: NSObject, SignInInteractable, ObservableObject {
    public let loginResult = PassthroughSubject<Bool, SwiftError>()
    public let logoutResult = PassthroughSubject<Bool, Never>()

    init(configurator: SignInConfigurator,
         presenter: UIViewController,
         model: SignInModel) {
        self.configurator = configurator
        self.presenter = presenter
        self.model = model
        super.init()
        self.configure()
    }
    
    private var configurator: SignInConfigurator
    private var presenter: UIViewController
    private var model: SignInModel

    @Published private var currentUser: GoogleUser?
    public var user: Published<GoogleUser?>.Publisher { $currentUser }

    private var cancellableBag = Set<AnyCancellable>()

    func configure() {
        Task {
            await restorePreviousUser()
            suscribeOnUser()
        }
    }

    private func suscribeOnUser() {
        model.$user
            .sink { [unowned self] in
                self.currentUser = $0
            }
            .store(in: &self.cancellableBag)
    }

    private func restorePreviousUser() async {
        do {
            let previousUser = await asyncRestorePreviousUser()
            try model.createUserAccount(for: previousUser)
        } catch SignInError.failedUserData {
            fatalError("Unexpected exception")
        } catch {
            fatalError("Unexpected exception")
        }
    }

    private func asyncRestorePreviousUser() async -> GIDGoogleUser {
        return await withCheckedContinuation { continuation in
            // source here: https://developers.google.com/identity/sign-in/ios/sign-in#3_attempt_to_restore_the_users_sign-in_state
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, _ in
                guard let user = user else { return }
                continuation.resume(with: .success(user))
            }
        }
    }

    // Retrieving user information
    public func signIn() {
        // https://developers.google.com/identity/sign-in/ios/people#retrieving_user_information
        GIDSignIn.sharedInstance.signIn(with: configurator.signInConfig,
                                        presenting: presenter) { [weak self] user, error in
            guard let `self` = self else { return }
            self.handleSignInResult(user, error)
        }
    }

    public func logOut() {
        GIDSignIn.sharedInstance.signOut()
        model.deleteLocalUserAccount()
        logoutResult.send(true)
    }

    // It is highly recommended that you provide users that signed in with Google the
    // ability to disconnect their Google account from your app. If the user deletes their account,
    // you must delete the information that your app obtained from the Google APIs.
    public func disconnect() {
        GIDSignIn.sharedInstance.disconnect { error in
            guard error == nil else { return }
            // Google Account disconnected from your app.
            // Perform clean-up actions, such as deleting data associated with the
            //   disconnected account.
            self.logOut()
        }
    }
}

// MARK: - Google Sign In Handler

extension Interactor {
    private func handleSignInResult(_ user: GIDGoogleUser?, _ error: Error?) {
        do {
            try self.parseSignInResult(user, error)
            self.loginResult.send(true)
        } catch SignInError.signInError(let error) {
            if (error as NSError).code == GIDSignInError.hasNoAuthInKeychain.rawValue {
                self.loginResult.send(completion: .failure(.systemMessage(401, SignInError.signInError(error).localizedString())))
            } else {
                self.loginResult.send(completion: .failure(.message(error.localizedDescription)))
            }
        } catch SignInError.userIsUndefined {
            self.loginResult.send(completion: .failure(.systemMessage(401, SignInError.userIsUndefined.localizedString())))
        } catch SignInError.permissionsError {
            self.loginResult.send(completion: .failure(.systemMessage(501, SignInError.permissionsError.localizedString())))
        } catch SignInError.failedUserData {
            self.loginResult.send(completion: .failure(.message(SignInError.failedUserData.localizedString())))
        } catch {
            fatalError("Unexpected exception")
        }
    }

    private func parseSignInResult(_ user: GIDGoogleUser?, _ error: Error?) throws {
        if let error = error {
            throw SignInError.signInError(error)
        } else if user == nil {
            throw SignInError.userIsUndefined
        } else if let user = user, checkPermissions(for: user) {
            do {
                try model.createUserAccount(for: user)
            } catch SignInError.failedUserData {
                throw SignInError.failedUserData
            } catch {
                fatalError("Unexpected exception")
            }
        } else {
            throw SignInError.permissionsError
        }
    }
    // [END signin_handler]
}

// MARK: - Check/Add the Scopes

extension Interactor {
    fileprivate struct Auth {
        // There are needed sensitive scopes to have ability to work properly
        // Make sure they are presented in your app. Then send request on verification
        static let scope1 = "https://www.googleapis.com/auth/youtube"
        static let scope2 = "https://www.googleapis.com/auth/youtube.readonly"
        static let scope3 = "https://www.googleapis.com/auth/youtube.force-ssl"
        static let scopes = [scope1, scope2, scope3]
    }

    private func checkPermissions(for user: GIDGoogleUser) -> Bool {
        guard let grantedScopes = user.grantedScopes else { return false }
        let currentScopes = grantedScopes.compactMap { $0 }
        let havePermissions = currentScopes.contains(where: { Auth.scopes.contains($0) })
        return havePermissions
    }

    public func addPermissions() {
        // Your app should be verified already, so it does not make sense. I think so.
        GIDSignIn.sharedInstance.addScopes(Auth.scopes,
                                           presenting: self.presenter,
                                           callback: { [weak self] user, error in
            self?.handleSignInResult(user, error)
        })
    }
}