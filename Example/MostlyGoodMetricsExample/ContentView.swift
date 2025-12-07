import SwiftUI
import MostlyGoodMetrics

struct ContentView: View {
    @State private var userId: String = ""
    @State private var eventName: String = "button_tapped"
    @State private var pendingEvents: Int = 0
    @State private var logMessages: [String] = []

    var body: some View {
        NavigationView {
            List {
                Section("User Identity") {
                    TextField("User ID", text: $userId)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)

                    HStack {
                        Button("Identify") {
                            guard !userId.isEmpty else { return }
                            MostlyGoodMetrics.identify(userId: userId)
                            log("Identified user: \(userId)")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reset") {
                            MostlyGoodMetrics.shared?.resetIdentity()
                            userId = ""
                            log("Reset user identity")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Track Events") {
                    TextField("Event Name", text: $eventName)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)

                    Button("Track Event") {
                        MostlyGoodMetrics.track(eventName)
                        log("Tracked: \(eventName)")
                        updatePendingCount()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Track with Properties") {
                        MostlyGoodMetrics.track(eventName, properties: [
                            "source": "example_app",
                            "timestamp": Date().timeIntervalSince1970,
                            "is_test": true
                        ])
                        log("Tracked: \(eventName) with properties")
                        updatePendingCount()
                    }
                    .buttonStyle(.bordered)
                }

                Section("Quick Events") {
                    Button("Track: screen_viewed") {
                        MostlyGoodMetrics.track("screen_viewed", properties: [
                            "screen_name": "main",
                            "screen_class": "ContentView"
                        ])
                        log("Tracked: screen_viewed")
                        updatePendingCount()
                    }

                    Button("Track: purchase_completed") {
                        MostlyGoodMetrics.track("purchase_completed", properties: [
                            "product_id": "premium_subscription",
                            "price": 9.99,
                            "currency": "USD"
                        ])
                        log("Tracked: purchase_completed")
                        updatePendingCount()
                    }

                    Button("Track: feature_used") {
                        MostlyGoodMetrics.track("feature_used", properties: [
                            "feature_name": "dark_mode",
                            "enabled": true
                        ])
                        log("Tracked: feature_used")
                        updatePendingCount()
                    }
                }

                Section("Flush") {
                    HStack {
                        Text("Pending Events")
                        Spacer()
                        Text("\(pendingEvents)")
                            .foregroundColor(.secondary)
                    }

                    Button("Flush Now") {
                        MostlyGoodMetrics.flush()
                        log("Flushing events...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            updatePendingCount()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clear Pending Events") {
                        MostlyGoodMetrics.shared?.clearPendingEvents()
                        log("Cleared pending events")
                        updatePendingCount()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }

                Section("Log") {
                    if logMessages.isEmpty {
                        Text("No events logged yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(logMessages.reversed(), id: \.self) { message in
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !logMessages.isEmpty {
                        Button("Clear Log") {
                            logMessages.removeAll()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("MGM Example")
            .onAppear {
                updatePendingCount()
                log("App appeared")
            }
        }
    }

    private func updatePendingCount() {
        pendingEvents = MostlyGoodMetrics.shared?.pendingEventCount ?? 0
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        logMessages.append("[\(timestamp)] \(message)")
    }
}

#Preview {
    ContentView()
}
