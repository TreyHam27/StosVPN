//
//  ContentView.swift
//  StosVPN
//
//  Created by Stossy11 on 28/03/2025.
//

import SwiftUI
import Foundation
import NetworkExtension


// MARK: - Logging Utility
class VPNLogger: ObservableObject {
    @Published var logs: [String] = []
    
    static var shared = VPNLogger()
    
    private init() {}
    
    func log(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        print("[\(fileName):\(line)] \(function): \(message)")
        #endif
        
        logs.append("\(message)")
    }
}

// MARK: - Tunnel Manager
class TunnelManager: ObservableObject {
    @Published var hasLocalDeviceSupport = false
    @Published var tunnelStatus: TunnelStatus = .disconnected
    
    static var shared = TunnelManager()
    
    private var vpnManager: NETunnelProviderManager?
    private var vpnObserver: NSObjectProtocol?
    
    private var tunnelDeviceIp: String {
        UserDefaults.standard.string(forKey: "TunnelDeviceIP") ?? "10.7.0.0"
    }
    
    private var tunnelFakeIp: String {
        UserDefaults.standard.string(forKey: "TunnelFakeIP") ?? "10.7.0.1"
    }
    
    private var tunnelSubnetMask: String {
        UserDefaults.standard.string(forKey: "TunnelSubnetMask") ?? "255.255.255.0"
    }
    
    private var tunnelBundleId: String {
        Bundle.main.bundleIdentifier!.appending(".TunnelProv")
    }
    
    enum TunnelStatus: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case disconnecting = "Disconnecting"
        case error = "Error"
        
        var color: Color {
            switch self {
            case .disconnected: return .gray
            case .connecting: return .orange
            case .connected: return .green
            case .disconnecting: return .orange
            case .error: return .red
            }
        }
        
        var systemImage: String {
            switch self {
            case .disconnected: return "network.slash"
            case .connecting: return "network.badge.shield.half.filled"
            case .connected: return "checkmark.shield.fill"
            case .disconnecting: return "network.badge.shield.half.filled"
            case .error: return "exclamationmark.shield.fill"
            }
        }
    }
    
    private init() {
        loadTunnelPreferences()
        setupStatusObserver()
    }
    
    // MARK: - Private Methods
    private func loadTunnelPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                
                if let error = error {
                    VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                    self.tunnelStatus = .error
                    return
                }
                
                self.hasLocalDeviceSupport = true
                
                if let managers = managers, !managers.isEmpty {
                    for manager in managers {
                        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
                           proto.providerBundleIdentifier == self.tunnelBundleId {
                            self.vpnManager = manager
                            self.updateTunnelStatus(from: manager.connection.status)
                            VPNLogger.shared.log("Loaded existing tunnel configuration")
                            break
                        }
                    }
                    
                    // If we didn't find a matching manager, use the first one
                    if self.vpnManager == nil, let firstManager = managers.first {
                        self.vpnManager = firstManager
                        self.updateTunnelStatus(from: firstManager.connection.status)
                        VPNLogger.shared.log("Using existing tunnel configuration")
                    }
                } else {
                    VPNLogger.shared.log("No existing tunnel configuration found")
                }
            }
        }
    }
    
    private func setupStatusObserver() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let connection = notification.object as? NEVPNConnection else {
                return
            }
            
            self.updateTunnelStatus(from: connection.status)
        }
    }
    
    private func updateTunnelStatus(from connectionStatus: NEVPNStatus) {
        DispatchQueue.main.async {
            switch connectionStatus {
            case .invalid, .disconnected:
                self.tunnelStatus = .disconnected
            case .connecting:
                self.tunnelStatus = .connecting
            case .connected:
                self.tunnelStatus = .connected
            case .disconnecting:
                self.tunnelStatus = .disconnecting
            case .reasserting:
                self.tunnelStatus = .connecting
            @unknown default:
                self.tunnelStatus = .error
            }
            
            VPNLogger.shared.log("VPN status updated: \(self.tunnelStatus.rawValue)")
        }
    }
    
    private func createOrUpdateTunnelConfiguration(completion: @escaping (Bool) -> Void) {
        // First check if we already have configurations
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return completion(false) }
            
            if let error = error {
                VPNLogger.shared.log("Error loading preferences: \(error.localizedDescription)")
                return completion(false)
            }
            
            let manager: NETunnelProviderManager
            if let existingManagers = managers, !existingManagers.isEmpty {
                if let matchingManager = existingManagers.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId
                }) {
                    manager = matchingManager
                    VPNLogger.shared.log("Updating existing tunnel configuration")
                } else {
                    manager = existingManagers[0]
                    VPNLogger.shared.log("Using first available tunnel configuration")
                }
            } else {
                // Create a new manager if none exists
                manager = NETunnelProviderManager()
                VPNLogger.shared.log("Creating new tunnel configuration")
            }
            
            manager.localizedDescription = "StosVPN"
            
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "StosVPN's Local Network Tunnel"
            manager.protocolConfiguration = proto
            
            let onDemandRule = NEOnDemandRuleEvaluateConnection()
            onDemandRule.interfaceTypeMatch = .any
            onDemandRule.connectionRules = [NEEvaluateConnectionRule(
                matchDomains: ["localhost"],
                andAction: .connectIfNeeded
            )]
            
            manager.onDemandRules = [onDemandRule]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            
            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return completion(false) }
                
                DispatchQueue.main.async {
                    if let error = error {
                        VPNLogger.shared.log("Error saving tunnel configuration: \(error.localizedDescription)")
                        completion(false)
                        return
                    }
                    
                    self.vpnManager = manager
                    VPNLogger.shared.log("Tunnel configuration saved successfully")
                    completion(true)
                }
            }
        }
    }
    
    // MARK: - Public Methods
    
    func toggleVPNConnection() {
        if tunnelStatus == .connected || tunnelStatus == .connecting {
            stopVPN()
        } else {
            startVPN()
        }
    }
    
    func startVPN() {
        if let manager = vpnManager {
            startExistingVPN(manager: manager)
        } else {
            createOrUpdateTunnelConfiguration { [weak self] success in
                guard let self = self, success else { return }
                self.loadTunnelPreferences()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let manager = self.vpnManager {
                        self.startExistingVPN(manager: manager)
                    }
                }
            }
        }
    }
    
    private func startExistingVPN(manager: NETunnelProviderManager) {
        guard tunnelStatus != .connected else {
            VPNLogger.shared.log("Network tunnel is already connected")
            return
        }
        
        tunnelStatus = .connecting
        
        let options: [String: NSObject] = [
            "TunnelDeviceIP": tunnelDeviceIp as NSObject,
            "TunnelFakeIP": tunnelFakeIp as NSObject,
            "TunnelSubnetMask": tunnelSubnetMask as NSObject
        ]
        
        do {
            try manager.connection.startVPNTunnel(options: options)
            VPNLogger.shared.log("Network tunnel start initiated")
        } catch {
            tunnelStatus = .error
            VPNLogger.shared.log("Failed to start tunnel: \(error.localizedDescription)")
        }
    }
    
    func stopVPN() {
        guard let manager = vpnManager else { return }
        
        tunnelStatus = .disconnecting
        manager.connection.stopVPNTunnel()
        VPNLogger.shared.log("Network tunnel stop initiated")
    }
    
    deinit {
        if let observer = vpnObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var showSettings = false
    @State var tunnel = false
    @AppStorage("autoConnect") private var autoConnect = false
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                StatusIndicatorView()
                
                ConnectionButton(
                    action: {
                        tunnelManager.tunnelStatus == .connected ? tunnelManager.stopVPN() : tunnelManager.startVPN()
                    }
                )
                
                Spacer()
                
                if tunnelManager.tunnelStatus == .connected {
                    ConnectionStatsView()
                }
            }
            .padding()
            .navigationTitle("StosVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(.primary)
                    }
                }
            }
            .onAppear() {
                if tunnelManager.tunnelStatus != .connected && autoConnect {
                    tunnelManager.startVPN()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $hasNotCompletedSetup) {
                SetupView()
            }
        }
    }
}


struct StatusIndicatorView: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    @State private var animationAmount = 1.0
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(tunnelManager.tunnelStatus.color.opacity(0.2), lineWidth: 20)
                    .frame(width: 200, height: 200)
                
                Circle()
                    .stroke(tunnelManager.tunnelStatus.color, lineWidth: 10)
                    .frame(width: 200, height: 200)
                    .scaleEffect(animationAmount)
                    .opacity(2 - animationAmount)
                    .animation(isAnimating ? Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false) : .default, value: animationAmount)
                
                VStack(spacing: 10) {
                    Image(systemName: tunnelManager.tunnelStatus.systemImage)
                        .font(.system(size: 50))
                        .foregroundColor(tunnelManager.tunnelStatus.color)
                    
                    Text(tunnelManager.tunnelStatus.rawValue)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            .onAppear {
                updateAnimation()
            }
            .onChange(of: tunnelManager.tunnelStatus) { _ in
                updateAnimation()
            }
            
            Text(tunnelManager.tunnelStatus == .connected ? "Tunnel active" : "Tunnel inactive")
                .font(.subheadline)
                .foregroundColor(tunnelManager.tunnelStatus == .connected ? .green : .secondary)
        }
    }
    
    private func updateAnimation() {
        switch tunnelManager.tunnelStatus {
        case .disconnecting:
            isAnimating = false
            withAnimation {
                animationAmount = 1.0
            }
        case .disconnected:
            isAnimating = false
            animationAmount = 1.0
        default:
            isAnimating = true
            animationAmount = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    animationAmount = 2.0
                }
            }
        }
    }
}


struct ConnectionButton: View {
    @StateObject private var tunnelManager = TunnelManager.shared
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(buttonText)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                if tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .padding(.leading, 5)
                }
            }
            .frame(width: 200, height: 50)
            .background(buttonBackground)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        .disabled(tunnelManager.tunnelStatus == .connecting || tunnelManager.tunnelStatus == .disconnecting)
    }
    
    private var buttonText: String {
        if tunnelManager.tunnelStatus == .connected {
            return "Disconnect"
        } else if tunnelManager.tunnelStatus == .connecting {
            return "Connecting..."
        } else if tunnelManager.tunnelStatus == .disconnecting {
            return "Disconnecting..."
        } else {
            return "Connect"
        }
    }
    
    private var buttonBackground: some View {
        Group {
            if tunnelManager.tunnelStatus == .connected {
                LinearGradient(
                    gradient: Gradient(colors: [Color.red.opacity(0.8), Color.red]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }
}

struct ConnectionStatsView: View {
    @State private var time = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 25) {
            Text("Connection Details")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(spacing: 30) {
                StatItemView(
                    title: "Time Connected",
                    value: formattedTime,
                    icon: "clock.fill"
                )
                
                StatItemView(
                    title: "Status",
                    value: "Active",
                    icon: "checkmark.circle.fill"
                )
            }
            
            HStack(spacing: 30) {
                StatItemView(
                    title: "Network Interface",
                    value: "Local",
                    icon: "network"
                )
                
                StatItemView(
                    title: "Assigned IP",
                    value: "10.7.0.1",
                    icon: "number"
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(UIColor.darkGray))
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
        .onReceive(timer) { _ in
            time += 1
        }
    }
    
    var formattedTime: String {
        let minutes = (time / 60) % 60
        let hours = time / 3600
        let seconds = time % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct StatItemView: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("TunnelDeviceIP") private var deviceIP = "10.7.0.0"
    @AppStorage("TunnelFakeIP") private var fakeIP = "10.7.0.1"
    @AppStorage("TunnelSubnetMask") private var subnetMask = "255.255.255.0"
    @AppStorage("autoConnect") private var autoConnect = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Connection Settings")) {
                    Toggle("Auto-connect on Launch", isOn: $autoConnect)
                    
                    NavigationLink(destination: ConnectionLogView()) {
                        Label("Connection Logs", systemImage: "doc.text")
                    }
                }
                
                Section(header: Text("Network Configuration")) {
                    HStack {
                        Text("Device IP")
                        Spacer()
                        TextField("Device IP", text: $deviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    
                    HStack {
                        Text("Tunnel IP")
                        Spacer()
                        TextField("Tunnel IP", text: $fakeIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    
                    HStack {
                        Text("Subnet Mask")
                        Spacer()
                        TextField("Subnet Mask", text: $subnetMask)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    Button("Privacy Policy") {
                        UIApplication.shared.open(URL(string: "https://github.com/stossy11/PrivacyPolicy/blob/main/PrivacyPolicy.md")!)
                    }
                    
                    NavigationLink(destination: HelpView()) {
                        Text("Help & Support")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}


struct ConnectionLogView: View {
    @StateObject var logger = VPNLogger.shared
    var body: some View {
        List(logger.logs, id: \.self) { log in
            Text(log)
                .font(.system(.body, design: .monospaced))
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("Privacy Policy")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                Text("Your privacy is important to us. This application is designed to create a local network interface for development and testing purposes.")
                
                Text("Data Collection")
                    .font(.headline)
                    .padding(.top, 10)
                
                Text("This application does not collect any personal information. All traffic remains on your device.")
                
                Text("Permissions")
                    .font(.headline)
                    .padding(.top, 10)
                
                Text("This app requires network extension permissions to create a virtual network interface on your device.")
            }
            .padding()
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section(header: Text("Frequently Asked Questions")) {
                NavigationLink("What does this app do?") {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("This app creates a local network interface that can be used for development and testing purposes.")
                            .padding(.bottom, 10)
                        
                        Text("Common use cases include:")
                            .fontWeight(.medium)
                        
                        Text("• Testing applications that require specific network configurations")
                        Text("• Development of network-related features")
                        Text("• Isolating network traffic for analysis or debugging")
                    }
                    .padding()
                }
                
                NavigationLink("Why does the connection fail?") {
                    
                    Text("Why does the connection fail?")
                        .fontWeight(.medium)
                    
                    Text("Connection failures could be due to system permission issues, configuration errors, or iOS restrictions. Try restarting the app or checking your settings.")
                        .padding()
                }
                
                NavigationLink("What is this app for?") {
                    
                    Text("What is this app for?")
                        .fontWeight(.medium)
                    
                    Text("This app is for connecting to local Servers on iOS devices to debug or test specific network applications, such as web-servers, or other network-related applications.")
                        .padding()
                }
            }
            
            Section(header: Text("App Information")) {
                HStack {
                    Image(systemName: "exclamationmark.shield")
                    Text("Requires iOS 16.0 or later")
                }
                
                HStack {
                    Image(systemName: "lock.shield")
                    Text("Uses Apple's Network Extension API")
                }
            }
        }
        .navigationTitle("Help & Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasNotCompletedSetup") private var hasNotCompletedSetup = true
    @State private var currentPage = 0
    
    let pages = [
        SetupPage(
            title: "Welcome to StosVPN",
            description: "A simple local network tunnel for everyone",
            imageName: "checkmark.shield.fill",
            details: "StosVPN creates a local network interface on your device that anyone can use for development, testing, and accessing local servers."
        ),
        SetupPage(
            title: "Why Use StosVPN?",
            description: "Perfect for developers and everyday users",
            imageName: "person.2.fill",
            details: "• Access local web servers and development environments\n• Test applications that require specific network configurations\n• Connect to local network services without complex setup\n• Create isolated network environments for testing"
        ),
        SetupPage(
            title: "Easy to Use",
            description: "Just one tap to connect",
            imageName: "hand.tap.fill",
            details: "StosVPN is designed to be simple and straightforward. Just tap the connect button to establish a local network tunnel with pre-configured settings that work for most users."
        ),
        SetupPage(
            title: "Privacy Focused",
            description: "Your data stays on your device",
            imageName: "lock.shield.fill",
            details: "StosVPN creates a local tunnel that doesn't route traffic through external servers. All network traffic remains on your device, ensuring your privacy and security."
        )
    ]
    
    var body: some View {
        NavigationStack {
            VStack {
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        SetupPageView(page: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
                
                Spacer()
                
                if currentPage == pages.count - 1 {
                    Button {
                        hasNotCompletedSetup = false
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                } else {
                    Button {
                        withAnimation {
                            currentPage += 1
                        }
                    } label: {
                        Text("Next")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue.opacity(0.8), Color.blue]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SetupPage {
    let title: String
    let description: String
    let imageName: String
    let details: String
}

struct SetupPageView: View {
    let page: SetupPage
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: page.imageName)
                .font(.system(size: 80))
                .foregroundColor(.blue)
                .padding(.top, 50)
            
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text(page.description)
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            ScrollView {
                Text(page.details)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
