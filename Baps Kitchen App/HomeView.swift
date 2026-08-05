import SwiftUI
import GoogleSignInSwift
import UIKit

struct HomeView: View {
    // 1. Initialize the ViewModel here so it persists across all screens
    @StateObject private var viewModel = InventoryViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Background Gradient
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.91, blue: 0.79),
                        Color(red: 0.91, green: 0.96, blue: 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 48) {
                    // ── Header ──────────────────────────────────────────
                    VStack(spacing: 14) {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(Color(red: 0.67, green: 0.48, blue: 0.29))
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

                        Text("Baps Kitchen")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))

                        Text("Inventory Manager")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.28))
                    }
                    .padding(.top, 40)

                    // ── Mode cards ──────────────────────────────────────
                    VStack(spacing: 20) {
                        NavigationLink(destination: ContentView(isEditMode: false, viewModel: viewModel)) {
                            HomeModeCard(
                                title: "View Inventory",
                                subtitle: "Check stock levels & details",
                                systemImage: "eye.fill",
                                accentColor: Color(red: 0.35, green: 0.45, blue: 0.22)
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink(destination: LoginView(viewModel: viewModel)) {
                            HomeModeCard(
                                title: "Update Inventory",
                                subtitle: "Sign in to edit inventory",
                                systemImage: "pencil.and.outline",
                                accentColor: Color(red: 0.60, green: 0.43, blue: 0.20)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            // 2. Pre-load the data when HomeView first appears
            .task {
                if viewModel.categories.isEmpty {
                    await viewModel.loadInventory()
                }
            }
        }
    }
}

private struct LoginView: View {
    @ObservedObject var viewModel: InventoryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var showEditor = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.91, blue: 0.79),
                    Color(red: 0.91, green: 0.96, blue: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { geometry in
                VStack {
                    Spacer()

                    VStack(spacing: 24) {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 72))
                                .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))

                            Text("Editor Login")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))

                            Text("Only certain Google Accounts can access edit mode")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.28))
                                .multilineTextAlignment(.center)
                        }

                        GoogleSignInButton(
                            viewModel: GoogleSignInButtonViewModel(
                                scheme: .light,
                                style: .wide,
                                state: isAuthenticating ? .disabled : .normal
                            )
                        ) {
                            authenticateWithGoogle()
                        }
                        .frame(height: 54)
                        .disabled(isAuthenticating)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.63, green: 0.23, blue: 0.18))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.white.opacity(0.88))
                                )
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .offset(y: -geometry.size.height * 0.12)

                    Spacer()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .navigationTitle("Login")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showEditor) {
            ContentView(isEditMode: true, onGoHome: goHome, viewModel: viewModel)
        }
    }

    private func goHome() {
        showEditor = false
        dismiss()
    }

    private func authenticateWithGoogle() {
        Task {
            isAuthenticating = true
            errorMessage = nil

            do {
                let success = try await viewModel.signInWithGoogle(
                    presentingViewController: topViewController()
                )
                if success {
                    showEditor = true
                }
            } catch {
                errorMessage = viewModel.accessDeniedMessage(for: error)
            }

            isAuthenticating = false
        }
    }

    private func topViewController() -> UIViewController {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let rootViewController = activeScene?
            .windows
            .first(where: \.isKeyWindow)?
            .rootViewController

        return rootViewController?.topMostPresentedViewController
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController?
                .topMostPresentedViewController
            ?? UIViewController()
    }
}

private extension UIViewController {
    var topMostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostPresentedViewController
        }
        if let navigationController = self as? UINavigationController {
            return navigationController.visibleViewController?.topMostPresentedViewController ?? navigationController
        }
        if let tabBarController = self as? UITabBarController {
            return tabBarController.selectedViewController?.topMostPresentedViewController ?? tabBarController
        }
        return self
    }
}

// ── Supporting View: HomeModeCard ──────────────────────────────────────────

struct HomeModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 18) {
            // Icon Container
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.13))

                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.28))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(red: 0.70, green: 0.58, blue: 0.42))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.95))
                .shadow(color: .black.opacity(0.06), radius: 15, x: 0, y: 8)
        )
    }
}

#Preview {
    HomeView()
}
