// MARK: - Managers
import Foundation
import StoreKit
import SwiftUI
import UIKit

// Base protocol for all Managers
protocol Manager { }

// UserManager to track onboarding status
@MainActor
class UserManager: Manager, ObservableObject {
    // Singleton instance
    static let shared = UserManager()
    
    @Published private(set) var hasCompletedOnboarding: Bool
    
    private init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
    
    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
    
    func resetOnboardingForTesting() {
        hasCompletedOnboarding = false
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        print("🧹 Onboarding has been reset for testing")
    }
}

@MainActor
class PurchaseManager: Manager {
    // Singleton instance
    static let shared = PurchaseManager()
    
    private let productIds = ["avacheck_proaccess_monthly", "avacheck_proaccess_annual"]
        
    @Published var products: [Product] = []
    private var productsLoaded = false
    
    @Published var purchasedProductIDs = Set<String>()
    
    @Published private(set) var isLoadingPro: Bool = false
    
    // Move the hasPro property from EntitlementManager directly into PurchaseManager
    @Published private(set) var hasPro: Bool = false

    var hasUnlockedPro: Bool {
       return !self.purchasedProductIDs.isEmpty
    }
    
    private var updates: Task<Void, Never>? = nil
    
    // Private initializer to enforce singleton usage
    private init() {
        // Load initial pro status from UserDefaults if needed
        self.hasPro = UserDefaults.standard.bool(forKey: "hasUnlockedPro")
        self.isLoadingPro = true  // Start with loading state
        self.updates = observeTransactionUpdates()
    }

    deinit {
        updates?.cancel()
    }

    func loadProducts() async throws {
        guard !self.productsLoaded else { return }
        self.products = try await Product.products(for: productIds)
        print("Loaded products \(self.products.count)")
        self.productsLoaded = true
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()

        switch result {
        case let .success(.verified(transaction)):
            // Successful purchase
            await transaction.finish()
            await self.updatePurchasedProducts()
        case let .success(.unverified(_, error)):
            // Successful purchase but transaction/receipt can't be verified
            // Could be a jailbroken phone
            break
        case .pending:
            // Transaction waiting on SCA (Strong Customer Authentication) or
            // approval from Ask to Buy
            break
        case .userCancelled:
            // User cancelled
            break
        @unknown default:
            break
        }
    }
    
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [unowned self] in
            for await verificationResult in Transaction.updates {
                await self.updatePurchasedProducts()
            }
        }
    }

    func updatePurchasedProducts() async {
        DispatchQueue.main.async {
            self.isLoadingPro = true
        }
        
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            if transaction.revocationDate == nil {
                self.purchasedProductIDs.insert(transaction.productID)
            } else {
                self.purchasedProductIDs.remove(transaction.productID)
            }
        }

        // Update the hasPro status directly
        let newProStatus = !self.purchasedProductIDs.isEmpty
        
        DispatchQueue.main.async {
            self.hasPro = newProStatus
            self.isLoadingPro = false
            
            // Save to UserDefaults if needed
            UserDefaults.standard.set(newProStatus, forKey: "hasUnlockedPro")
        }
    }
    
    func resetEntitlementsForTesting() {
        // Clear the hasUnlockedPro status
        purchasedProductIDs.removeAll()
        hasPro = false
        
        // Clear from UserDefaults
        UserDefaults.standard.removeObject(forKey: "hasUnlockedPro")
        
        // Any other entitlement states you're storing
        // UserDefaults.standard.removeObject(forKey: "purchasedFeatures")
        
        print("🧹 Entitlements have been reset for testing")
    }
}

// AppState to manage global app state
@MainActor
class AppState: ObservableObject {
    // Singleton instance
    static let shared = AppState()
    
    @Published var isPaywallPresented: Bool = false
    @Published var showCameraView: Bool = false
    
    private init() {}
}

// MARK: - ViewModels

// Main App ViewModel
@MainActor
class AppViewModel: ObservableObject {
    @Published var shouldShowOnboarding: Bool
    @Published var hasProAccess: Bool
    
    init() {
        self.shouldShowOnboarding = !UserManager.shared.hasCompletedOnboarding
        self.hasProAccess = PurchaseManager.shared.hasPro
        
        // Set up observers
        Task {
            for await _ in PurchaseManager.shared.$hasPro.values {
                self.hasProAccess = PurchaseManager.shared.hasPro
            }
        }
        
        Task {
            for await _ in UserManager.shared.$hasCompletedOnboarding.values {
                self.shouldShowOnboarding = !UserManager.shared.hasCompletedOnboarding
            }
        }
    }
}

// Home View ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    // New name to avoid conflict
    @Published private(set) var proStatus: Bool = false
    
    private let appState = AppState.shared
    
    init() {
        // Initialize with current status
        self.proStatus = PurchaseManager.shared.hasPro
        print("HomeViewModel init - Pro status: \(self.proStatus)")
        
        // Set up observer for pro status changes
        Task {
            print("HomeViewModel setting up hasPro observer")
            for await hasPro in PurchaseManager.shared.$hasPro.values {
                print("HomeViewModel received hasPro update: \(hasPro)")
                self.proStatus = hasPro
                print("HomeViewModel updated proStatus to \(self.proStatus)")
            }
        }
    }
    
    func showCamera() {
        appState.showCameraView = true
    }
    
    func showPaywall() {
        appState.isPaywallPresented = true
    }
    
    func checkProStatus() {
        // Force a refresh of pro status
        let currentStatus = PurchaseManager.shared.hasPro
        print("HomeViewModel checkProStatus - current status: \(currentStatus)")
        if self.proStatus != currentStatus {
            self.proStatus = currentStatus
            print("HomeViewModel updated proStatus to \(self.proStatus)")
        }
    }
    
    func resetProStatus() {
        print("🧹 Resetting Pro Status...")
        // Use the proper method from PurchaseManager to reset entitlements
        PurchaseManager.shared.resetEntitlementsForTesting()
        
        // Also update our local proStatus immediately for instant UI feedback
        self.proStatus = false
        
        print("✅ Pro Access Reset: proStatus = \(self.proStatus), PurchaseManager.hasPro = \(PurchaseManager.shared.hasPro)")
    }
}

// Onboarding View ViewModel
@MainActor
class OnboardingViewModel: ObservableObject {
    func completeOnboarding() {
        UserManager.shared.completeOnboarding()
    }
}

// Paywall View ViewModel
@MainActor
class PaywallViewModel: ObservableObject {
        
    @Published var products: [Product] = []
    @Published var isLoading: Bool = false
    
    init() {
        Task {
            isLoading = true
            try? await PurchaseManager.shared.loadProducts()
            self.products = PurchaseManager.shared.products
            isLoading = false
            print("My paywall products\(self.products)")
        }
        
        // Set up observers for loading state
        Task {
            for await isLoadingValue in PurchaseManager.shared.$isLoadingPro.values {
                self.isLoading = isLoadingValue
            }
        }
    }
    
    func purchase(product: Product) async {
        do {
            try await PurchaseManager.shared.purchase(product)
        } catch {
            print("Purchase error: \(error)")
        }
    }
    
    func closePaywall() {
        AppState.shared.isPaywallPresented = false
    }
}

// Camera View ViewModel
@MainActor
class CameraViewModel: ObservableObject {
    
    @Published private(set) var proStatus: Bool = false
    
    @Published var currentStep: Int = 0
    @Published var photos: [UIImage] = []
    
    private let appState = AppState.shared
    
    init() {
        // Initialize with current status
        self.proStatus = PurchaseManager.shared.hasPro
        print("CameraViewModel init - Pro status: \(self.proStatus)")
        
        // Set up observer for pro status changes
        Task {
            print("CameraViewModel setting up hasPro observer")
            for await hasPro in PurchaseManager.shared.$hasPro.values {
                print("CameraViewModel received hasPro update: \(hasPro)")
                self.proStatus = hasPro
                print("CameraViewModel updated proStatus to \(self.proStatus)")
            }
        }
    }
    
    func takePhoto(image: UIImage) {
        photos.append(image)
        moveToNextStep()
    }
    
    func moveToNextStep() {
        currentStep += 1
    }
    
    func moveToPreviousStep() {
        if currentStep > 0 {
            currentStep -= 1
        }
    }
    
    func closeCamera() {
        AppState.shared.showCameraView = false
    }
    
    func showPaywall() {
        appState.isPaywallPresented = true
    }
    
    func checkProStatus() {
        // Force a refresh of pro status
        let currentStatus = PurchaseManager.shared.hasPro
        print("HomeViewModel checkProStatus - current status: \(currentStatus)")
        if self.proStatus != currentStatus {
            self.proStatus = currentStatus
            print("HomeViewModel updated proStatus to \(self.proStatus)")
        }
    }
    
    func resetProStatus() {
        print("🧹 Resetting Pro Status...")
        // Use the proper method from PurchaseManager to reset entitlements
        PurchaseManager.shared.resetEntitlementsForTesting()
        
        // Also update our local proStatus immediately for instant UI feedback
        self.proStatus = false
        
        print("✅ Pro Access Reset: proStatus = \(self.proStatus), PurchaseManager.hasPro = \(PurchaseManager.shared.hasPro)")
    }

}

// MARK: - Views

// Main App View
struct AppView: View {
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var appState = AppState.shared
    
    var body: some View {
        Group {
            if viewModel.shouldShowOnboarding {
                OnboardingView()
            } else {
                // Show either HomeView or CameraView, not both
                if appState.showCameraView {
                    CameraView()
                } else {
                    HomeView()
                }
            }
        }
        .animation(.easeInOut, value: appState.showCameraView)
        .sheet(isPresented: $appState.isPaywallPresented) {
            PaywallView()
        }
    }
}
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            // Other content...
            
            // IMPORTANT: Changed from hasProAccess to proStatus
            if !viewModel.proStatus {
                Button("Go to Paywall") {
                    viewModel.showPaywall()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            } else {
                Text("Pro Access Enabled")
                    .foregroundColor(.green)
                    .padding()
            }
            Button("Reset Pro Access"){
                viewModel.resetProStatus()
            }
            Button("Go to Camera"){
                viewModel.showCamera()
            }

        }
        .onAppear {
            viewModel.checkProStatus()
        }
    }
}
// Onboarding View
struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    
    var body: some View {
        VStack {
            Text("Welcome to the App!")
            
            Button("Complete Onboarding") {
                viewModel.completeOnboarding()
            }
        }
    }
}

// Paywall View
struct PaywallView: View {
    @StateObject private var viewModel = PaywallViewModel()
    
    var body: some View {
        VStack {
            Text("Upgrade to Pro")
            
            if viewModel.isLoading {
                ProgressView()
            } else {
                ForEach(viewModel.products, id: \.id) { product in
                    Button(product.displayPrice) {
                        Task {
                            await viewModel.purchase(product: product)
                        }
                    }
                }
            }
            
            Button("Close") {
                viewModel.closePaywall()
            }
        }
    }
}

// Camera Main View
struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    
    var body: some View {
        VStack {
            if !viewModel.proStatus {
                Text("You Don't Have Pro Access")
                    .foregroundColor(.red)
                    .padding()
            } else {
                Text("Pro Access Enabled")
                    .foregroundColor(.green)
                    .padding()
            }
            Button("Reset Pro Access"){
                viewModel.resetProStatus()
            }
            Text("Step \(viewModel.currentStep + 1)")
            
            // Camera functionality would go here
            
            HStack {
                Button("Back") {
                    viewModel.moveToPreviousStep()
                }
                .disabled(viewModel.currentStep == 0)
                
                Button("Take Photo") {
                    if !viewModel.proStatus {
                        viewModel.showPaywall()
                    }
                    
                    // This would actually capture a photo
                    viewModel.takePhoto(image: UIImage())
                }
                
                Button("Close") {
                    viewModel.closeCamera()
                }
            }
        }
            .onAppear {
                viewModel.checkProStatus()
            }
    }
}



// MARK: - App Entry Point
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            AppView()
                .onAppear {
                    // Initialize managers
                    Task {
                        try? await PurchaseManager.shared.loadProducts()
                        await PurchaseManager.shared.updatePurchasedProducts()
                    }
                }
        }
    }
}
