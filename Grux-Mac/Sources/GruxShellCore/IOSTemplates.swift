import Foundation

// MARK: - iOS feature templates
//
// Each template returns a dictionary of `path relative to <projectName>/Sources/`
// → Swift file contents. Every template is pre-tested to compile clean against
// iOS 17 / Swift 5.9. Kept as string literals (not resource files) so the
// GruxShellCore library stays resource-free and easy to vendor.
//
// Design rule: NO unreachable placeholders. Every template must compile AS-IS -
// no "// TODO paste API key here" stubs that leave the build broken. Secrets
// come from Info.plist user-defaults keys at runtime, resolved via the user's
// Keychain on first launch.

public enum IOSTemplates {

    // MARK: App entry + root ContentView

    public static func appEntry(projectName: String) -> String {
        """
        import SwiftUI
        \(importsForAppEntry())

        @main
        struct \(projectName)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """
    }

    private static func importsForAppEntry() -> String { "" }

    public static func contentView(features: [IOSFeature]) -> String {
        let tabs = features.map { f -> String in
            switch f {
            case .chat:
                return "ChatView().tabItem { Label(\"Chat\", systemImage: \"bubble.left.and.bubble.right.fill\") }.tag(Tab.chat)"
            case .tasks:
                return "TasksView().tabItem { Label(\"Tasks\", systemImage: \"checkmark.circle.fill\") }.tag(Tab.tasks)"
            case .voiceMemos:
                return "VoiceMemosView().tabItem { Label(\"Voice\", systemImage: \"mic.fill\") }.tag(Tab.voice)"
            case .focusSummary:
                return "FocusView().tabItem { Label(\"Focus\", systemImage: \"brain.head.profile\") }.tag(Tab.focus)"
            }
        }.joined(separator: "\n                ")
        let firstTab: String = {
            guard let f = features.first else { return "Tab.chat" }
            switch f {
            case .chat: return "Tab.chat"
            case .tasks: return "Tab.tasks"
            case .voiceMemos: return "Tab.voice"
            case .focusSummary: return "Tab.focus"
            }
        }()
        return """
        import SwiftUI

        enum Tab: Hashable { case chat, tasks, voice, focus }

        struct ContentView: View {
            @State private var selection: Tab = \(firstTab)
            var body: some View {
                TabView(selection: $selection) {
                    \(tabs)
                }
                .accentColor(.blue)
            }
        }

        #Preview { ContentView() }
        """
    }

    // MARK: Chat - Anthropic API client with streaming-free default

    public static func chatView() -> String {
        """
        import SwiftUI

        struct ChatMessage: Identifiable, Equatable {
            let id = UUID()
            let role: String     // "user" or "assistant"
            let content: String
        }

        @MainActor
        final class ChatViewModel: ObservableObject {
            @Published var messages: [ChatMessage] = []
            @Published var inputText: String = ""
            @Published var isLoading: Bool = false
            @Published var error: String?

            func send() {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let user = ChatMessage(role: "user", content: text)
                messages.append(user)
                inputText = ""
                isLoading = true
                error = nil
                Task {
                    do {
                        let reply = try await AnthropicClient.shared.send(messages: messages)
                        self.messages.append(ChatMessage(role: "assistant", content: reply))
                    } catch {
                        self.error = error.localizedDescription
                    }
                    self.isLoading = false
                }
            }
        }

        struct ChatView: View {
            @StateObject private var vm = ChatViewModel()
            @State private var showingKey = false

            var body: some View {
                NavigationStack {
                    VStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(vm.messages) { msg in
                                        bubble(msg).id(msg.id)
                                    }
                                    if vm.isLoading {
                                        HStack { ProgressView().padding(); Spacer() }
                                    }
                                }.padding()
                            }
                            .onChange(of: vm.messages.count) { _, _ in
                                if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        if let err = vm.error {
                            Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal)
                        }
                        HStack {
                            TextField("Ask anything…", text: $vm.inputText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                                .onSubmit { vm.send() }
                            Button { vm.send() } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.title2)
                            }
                            .disabled(vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLoading)
                        }
                        .padding()
                    }
                    .navigationTitle("Chat")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showingKey = true } label: { Image(systemName: "key.fill") }
                        }
                    }
                    .sheet(isPresented: $showingKey) { APIKeySheet() }
                }
            }

            private func bubble(_ msg: ChatMessage) -> some View {
                HStack {
                    if msg.role == "user" { Spacer() }
                    Text(msg.content)
                        .padding(12)
                        .background(msg.role == "user" ? Color.blue : Color(.systemGray5))
                        .foregroundColor(msg.role == "user" ? .white : .primary)
                        .cornerRadius(16)
                    if msg.role == "assistant" { Spacer() }
                }
            }
        }

        #Preview { ChatView() }
        """
    }

    public static func anthropicClient() -> String {
        """
        import Foundation

        // Minimal Anthropic Messages API client. Non-streaming: sends the full
        // history and awaits a single JSON reply. API key stored in Keychain
        // under service "AnthropicAPIKey" - fetched on demand, cached in-process.

        struct AnthropicError: LocalizedError {
            let msg: String
            var errorDescription: String? { msg }
        }

        actor AnthropicClient {
            static let shared = AnthropicClient()

            private let model = "claude-sonnet-4-6"
            private let url = URL(string: "https://api.anthropic.com/v1/messages")!
            private var cachedKey: String?

            func send(messages: [ChatMessage]) async throws -> String {
                let key = try await apiKey()
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.addValue("application/json", forHTTPHeaderField: "Content-Type")
                req.addValue(key, forHTTPHeaderField: "x-api-key")
                req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                let payload: [String: Any] = [
                    "model": model,
                    "max_tokens": 1024,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] }
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw AnthropicError(msg: "no http response") }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? "?"
                    throw AnthropicError(msg: "HTTP \\(http.statusCode): \\(body.prefix(200))")
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = obj["content"] as? [[String: Any]],
                      let first = content.first,
                      let text = first["text"] as? String
                else { throw AnthropicError(msg: "malformed response") }
                return text
            }

            private func apiKey() async throws -> String {
                if let k = cachedKey { return k }
                if let k = Keychain.load(service: "AnthropicAPIKey") {
                    cachedKey = k; return k
                }
                throw AnthropicError(msg: "No API key. Tap the key icon in Chat to add one.")
            }

            func setKey(_ k: String) {
                cachedKey = k
                Keychain.save(service: "AnthropicAPIKey", value: k)
            }
        }
        """
    }

    public static func keychain() -> String {
        """
        import Foundation
        import Security

        // Tiny Keychain wrapper - stores one string per service name under the
        // app's default keychain group. No accessibility flag override: default
        // is kSecAttrAccessibleAfterFirstUnlock which is appropriate for an
        // API key that should survive reboots but not leave the device unlocked.

        enum Keychain {
            static func save(service: String, value: String) {
                let data = Data(value.utf8)
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "default"
                ]
                SecItemDelete(query as CFDictionary)
                var insert = query
                insert[kSecValueData as String] = data
                SecItemAdd(insert as CFDictionary, nil)
            }

            static func load(service: String) -> String? {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: "default",
                    kSecReturnData as String: true,
                    // A read never prompts. See KeychainStore.neverPrompt for why.
                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                guard status == errSecSuccess, let data = item as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
        """
    }

    public static func apiKeySheet() -> String {
        """
        import SwiftUI

        struct APIKeySheet: View {
            @Environment(\\.dismiss) private var dismiss
            @State private var key: String = ""

            var body: some View {
                NavigationStack {
                    Form {
                        Section("Anthropic API Key") {
                            SecureField("sk-ant-...", text: $key)
                            Text("Stored in the iOS Keychain. Used only to send your messages to Claude.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("API Key")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    Task { await AnthropicClient.shared.setKey(trimmed) }
                                }
                                dismiss()
                            }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .onAppear {
                        key = Keychain.load(service: "AnthropicAPIKey") ?? ""
                    }
                }
            }
        }
        """
    }

    // MARK: Voice memos + on-device transcription

    public static func voiceMemosView() -> String {
        """
        import SwiftUI
        import AVFoundation
        import Speech

        struct VoiceMemo: Identifiable, Hashable {
            let id = UUID()
            let fileURL: URL
            let createdAt: Date
            var transcript: String = ""
        }

        @MainActor
        final class VoiceMemosViewModel: NSObject, ObservableObject {
            @Published var memos: [VoiceMemo] = []
            @Published var isRecording: Bool = false
            @Published var error: String?

            private var recorder: AVAudioRecorder?
            private var currentURL: URL?

            func toggleRecord() async {
                if isRecording { await stop() } else { await start() }
            }

            private func start() async {
                do {
                    // iOS 17: AVAudioApplication replaces AVAudioSession for permission.
                    let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
                    }
                    guard granted else { error = "Mic permission denied"; return }
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    let url = documentsURL().appendingPathComponent("memo-\\(Int(Date().timeIntervalSince1970)).m4a")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                    let r = try AVAudioRecorder(url: url, settings: settings)
                    r.record()
                    recorder = r
                    currentURL = url
                    isRecording = true
                } catch {
                    self.error = error.localizedDescription
                }
            }

            private func stop() async {
                recorder?.stop()
                isRecording = false
                guard let url = currentURL else { return }
                var memo = VoiceMemo(fileURL: url, createdAt: Date())
                memos.insert(memo, at: 0)
                // Best-effort transcription. Uses SFSpeechRecognizer with on-device flag.
                let text = await transcribe(url: url)
                if let idx = memos.firstIndex(where: { $0.id == memo.id }) {
                    memos[idx].transcript = text
                }
                currentURL = nil
                recorder = nil
            }

            private func transcribe(url: URL) async -> String {
                let authorized = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { status in
                        cont.resume(returning: status == .authorized)
                    }
                }
                guard authorized else { return "(speech authorization denied)" }
                guard let recog = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recog.isAvailable else {
                    return "(recognizer unavailable)"
                }
                let req = SFSpeechURLRecognitionRequest(url: url)
                req.requiresOnDeviceRecognition = true
                req.shouldReportPartialResults = false
                return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    recog.recognitionTask(with: req) { result, err in
                        if let r = result, r.isFinal {
                            cont.resume(returning: r.bestTranscription.formattedString)
                        } else if err != nil {
                            cont.resume(returning: "(transcription error)")
                        }
                    }
                }
            }

            private func documentsURL() -> URL {
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            }
        }

        struct VoiceMemosView: View {
            @StateObject private var vm = VoiceMemosViewModel()
            var body: some View {
                NavigationStack {
                    List(vm.memos) { memo in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memo.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(memo.transcript.isEmpty ? "(transcribing…)" : memo.transcript)
                                .font(.body)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Button {
                            Task { await vm.toggleRecord() }
                        } label: {
                            ZStack {
                                Circle().fill(vm.isRecording ? .red : .blue).frame(width: 72, height: 72)
                                Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                                    .foregroundColor(.white).font(.title)
                            }
                        }
                        .padding(.bottom, 24)
                        .shadow(radius: 6)
                    }
                    .navigationTitle("Voice Memos")
                }
            }
        }

        #Preview { VoiceMemosView() }
        """
    }

    // MARK: Smart tasks - SwiftData

    public static func tasksView() -> String {
        """
        import SwiftUI
        import SwiftData

        @Model
        final class CapturedTask {
            var title: String
            var notes: String
            var isDone: Bool
            var createdAt: Date
            init(title: String, notes: String = "") {
                self.title = title
                self.notes = notes
                self.isDone = false
                self.createdAt = Date()
            }
        }

        struct TasksView: View {
            @Environment(\\.modelContext) private var ctx
            @Query(sort: \\CapturedTask.createdAt, order: .reverse) private var tasks: [CapturedTask]
            @State private var newTitle: String = ""
            @FocusState private var inputFocused: Bool

            var body: some View {
                NavigationStack {
                    List {
                        ForEach(tasks) { t in
                            HStack {
                                Button { t.isDone.toggle() } label: {
                                    Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(t.isDone ? .green : .secondary)
                                }.buttonStyle(.plain)
                                Text(t.title)
                                    .strikethrough(t.isDone)
                                    .foregroundColor(t.isDone ? .secondary : .primary)
                                Spacer()
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .navigationTitle("Tasks")
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            TextField("Quick capture…", text: $newTitle)
                                .textFieldStyle(.roundedBorder)
                                .focused($inputFocused)
                                .onSubmit(add)
                            Button { add() } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                            }.disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        }.padding()
                    }
                }
            }

            private func add() {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                ctx.insert(CapturedTask(title: title))
                newTitle = ""
            }

            private func delete(at offsets: IndexSet) {
                for i in offsets { ctx.delete(tasks[i]) }
            }
        }

        #Preview {
            TasksView().modelContainer(for: CapturedTask.self, inMemory: true)
        }
        """
    }

    // App entry needs to attach modelContainer if .tasks is enabled
    public static func appEntry(projectName: String, features: [IOSFeature]) -> String {
        let hasTasks = features.contains(.tasks)
        let hasFocus = features.contains(.focusSummary)
        let imports = [
            "import SwiftUI",
            hasTasks ? "import SwiftData" : nil,
            hasFocus ? "import UserNotifications" : nil
        ].compactMap { $0 }.joined(separator: "\n")
        let modifier = hasTasks ? ".modelContainer(for: CapturedTask.self)" : ""
        let focusHook = hasFocus ? """

            init() {
                FocusScheduler.shared.scheduleDailyIfNeeded()
            }
        """ : ""
        return """
        \(imports)

        @main
        struct \(projectName)App: App {\(focusHook)
            var body: some Scene {
                WindowGroup {
                    ContentView()\(modifier.isEmpty ? "" : "\n                        " + modifier)
                }
            }
        }
        """
    }

    // MARK: Daily focus summary

    public static func focusView() -> String {
        """
        import SwiftUI
        import UserNotifications

        @MainActor
        final class FocusViewModel: ObservableObject {
            @Published var authorized: Bool = false
            @Published var scheduled: Bool = false
            @Published var todaySummary: String = "Open the app each morning to see your daily focus summary here."

            func refresh() async {
                let s = await UNUserNotificationCenter.current().notificationSettings()
                authorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                scheduled = pending.contains(where: { $0.identifier == FocusScheduler.dailyId })
            }

            func enableDaily() async {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                authorized = granted
                if granted {
                    FocusScheduler.shared.scheduleDailyIfNeeded(force: true)
                    await refresh()
                }
            }
        }

        struct FocusView: View {
            @StateObject private var vm = FocusViewModel()
            var body: some View {
                NavigationStack {
                    Form {
                        Section("Today") {
                            Text(vm.todaySummary)
                        }
                        Section("Daily Summary Notification") {
                            HStack {
                                Text("Status")
                                Spacer()
                                Text(vm.scheduled ? "Scheduled 8:00 AM" : (vm.authorized ? "Authorized, not scheduled" : "Not authorized"))
                                    .foregroundStyle(.secondary)
                            }
                            if !vm.scheduled {
                                Button("Enable daily summary") { Task { await vm.enableDaily() } }
                            }
                        }
                    }
                    .navigationTitle("Focus")
                }
                .task { await vm.refresh() }
            }
        }

        #Preview { FocusView() }
        """
    }

    public static func focusScheduler() -> String {
        """
        import Foundation
        import UserNotifications

        // Schedules a local notification every morning at 8:00 AM with a brief
        // focus prompt. Idempotent - re-adding the same identifier replaces the
        // existing request, so this is safe to call on every app launch.

        final class FocusScheduler {
            static let shared = FocusScheduler()
            static let dailyId = "daily-focus-summary"

            func scheduleDailyIfNeeded(force: Bool = false) {
                let center = UNUserNotificationCenter.current()
                center.getPendingNotificationRequests { requests in
                    let alreadyScheduled = requests.contains(where: { $0.identifier == FocusScheduler.dailyId })
                    if alreadyScheduled && !force { return }
                    let content = UNMutableNotificationContent()
                    content.title = "Today's focus"
                    content.body = "What's the one thing that would move the needle today?"
                    content.sound = .default
                    var date = DateComponents()
                    date.hour = 8
                    date.minute = 0
                    let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
                    let request = UNNotificationRequest(identifier: FocusScheduler.dailyId, content: content, trigger: trigger)
                    center.add(request)
                }
            }
        }
        """
    }

    // MARK: Placeholder LaunchScreen + generated icon placeholder

    public static func launchScreenStoryboard(appName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="23081" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="01J-lp-oVM">
            <device id="retina6_12" orientation="portrait" appearance="light"/>
            <dependencies>
                <deployment identifier="iOS"/>
                <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="23067"/>
                <capability name="Safe area layout guides" minToolsVersion="9.0"/>
                <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
            </dependencies>
            <scenes>
                <scene sceneID="EHf-IW-A2E">
                    <objects>
                        <viewController id="01J-lp-oVM" sceneMemberID="viewController">
                            <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
                                <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
                                <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                                <subviews>
                                    <label opaque="NO" clipsSubviews="YES" userInteractionEnabled="NO" contentMode="left" horizontalHuggingPriority="251" verticalHuggingPriority="251" text="\(appName)" textAlignment="center" lineBreakMode="tailTruncation" baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO" translatesAutoresizingMaskIntoConstraints="NO" id="nxw-Rf-LRf">
                                        <rect key="frame" x="20" y="406" width="353" height="40"/>
                                        <fontDescription key="fontDescription" type="system" weight="semibold" pointSize="34"/>
                                        <color key="textColor" systemColor="labelColor"/>
                                        <nil key="highlightedColor"/>
                                    </label>
                                </subviews>
                                <viewLayoutGuide key="safeArea" id="6Tk-OE-BBY"/>
                                <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                                <constraints>
                                    <constraint firstItem="nxw-Rf-LRf" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="Aqw-Xw-AqA"/>
                                    <constraint firstItem="nxw-Rf-LRf" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="cBB-V2-SdW"/>
                                </constraints>
                            </view>
                        </viewController>
                        <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
                    </objects>
                    <point key="canvasLocation" x="53" y="375"/>
                </scene>
            </scenes>
        </document>
        """
    }

    // MARK: AppIcon.appiconset Contents.json + single 1024 icon

    public static func appIconContentsJSON() -> String {
        """
        {
          "images" : [
            {
              "filename" : "Icon-1024.png",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
    }

    // README shipped alongside so the user knows how to open + run.
    public static func readme(projectName: String, bundleId: String, features: [IOSFeature]) -> String {
        let featLines = features.map { "- \($0.label)" }.joined(separator: "\n")
        return """
        # \(projectName)

        Generated by Grux. Bundle ID: `\(bundleId)`

        ## Features
        \(featLines)

        ## Build

            xcodegen generate
            open \(projectName).xcodeproj

        Or from the command line:

            xcodebuild -scheme \(projectName) -destination 'platform=iOS Simulator,name=iPhone 16' build

        ## Configure

        - Chat: tap the key icon in the Chat tab, paste your Anthropic API key.
        - Voice Memos: will prompt for mic + speech recognition on first record.
        - Focus: tap "Enable daily summary" to schedule the 8 AM notification.
        """
    }
}
