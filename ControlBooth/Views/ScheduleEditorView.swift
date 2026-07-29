import AppKit
import SwiftUI

struct ScheduleEditorView: View {
    @Environment(ScheduledEventStore.self) private var eventStore
    @Environment(PipelineStore.self) private var pipelineStore
    @Environment(Scheduler.self) private var scheduler
    @Environment(PipelineRunner.self) private var runner

    let event: ScheduledEvent
    @State private var name: String
    @State private var pipelineId: Int64
    @State private var daysOfWeek: Int
    @State private var startTimeSeconds: Int
    @State private var durationSeconds: Int
    @State private var isEnabled: Bool
    @State private var recordingDirectory: String?
    @State private var recordingBookmark: String?
    @State private var errorMessage: String?

    private static let dayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(event: ScheduledEvent) {
        self.event = event
        _name             = State(initialValue: event.name)
        _pipelineId       = State(initialValue: event.pipelineId)
        _daysOfWeek       = State(initialValue: event.daysOfWeek)
        _startTimeSeconds = State(initialValue: event.startTimeSeconds)
        _durationSeconds  = State(initialValue: event.durationSeconds)
        _isEnabled           = State(initialValue: event.isEnabled)
        _recordingDirectory  = State(initialValue: event.recordingDirectory)
        _recordingBookmark   = State(initialValue: event.recordingBookmark)
    }

    var body: some View {
        Form {
            Section("Event") {
                TextField("Name", text: $name)
                Toggle("Enabled", isOn: $isEnabled)
            }

            Section("Pipeline") {
                Picker("Pipeline", selection: $pipelineId) {
                    ForEach(pipelineStore.pipelines) { p in
                        Text(p.name).tag(p.id ?? Int64(0))
                    }
                }
            }

            Section("Days") {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        let enabled = daysOfWeek & (1 << day) != 0
                        Button(Self.dayAbbreviations[day]) {
                            if enabled {
                                daysOfWeek &= ~(1 << day)
                            } else {
                                daysOfWeek |= (1 << day)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(enabled ? .accentColor : nil)
                    }
                }
            }

            Section("Timing") {
                DatePicker("Start", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                Picker("Duration", selection: $durationSeconds) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(5 * 60)
                    Text("10 minutes").tag(10 * 60)
                    Text("15 minutes").tag(15 * 60)
                    Text("30 minutes").tag(30 * 60)
                    Text("45 minutes").tag(45 * 60)
                    Text("1 hour").tag(3600)
                    Text("1.5 hours").tag(90 * 60)
                    Text("2 hours").tag(2 * 3600)
                    Text("3 hours").tag(3 * 3600)
                    Text("4 hours").tag(4 * 3600)
                    Text("6 hours").tag(6 * 3600)
                    Text("12 hours").tag(12 * 3600)
                    Text("24 hours").tag(24 * 3600)
                }
            }

            Section("Recording") {
                if let dir = recordingDirectory {
                    LabeledContent("Folder") {
                        HStack {
                            Text(dir)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Change…") { pickFolder() }
                            Button("Clear") {
                                recordingDirectory = nil
                                recordingBookmark = nil
                            }
                        }
                    }
                    HStack {
                        Button("Test Connection") { testConnection() }
                            .help("Sends a 'Runs' query to AntennaHead to verify the Apple Event channel works")
                        Button("Test Recording Now") { testRecording() }
                            .help("Immediately starts a recording in the chosen folder")
                    }
                } else {
                    HStack {
                        Text("Not recording")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Folder…") { pickFolder() }
                    }
                }
            }

            if let err = scheduler.lastError {
                Section("Last Error") {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if let draft = draftEvent, let nextFire = draft.nextFireDate() {
                Section("Next Scheduled Run") {
                    LabeledContent("Fires", value: nextFire.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Ends", value: nextFire.addingTimeInterval(TimeInterval(durationSeconds)).formatted(date: .omitted, time: .shortened))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name.isEmpty ? "Event" : name)
        .toolbar {
            ToolbarItemGroup {
                Button("Save") { save() }
                    .disabled(!isDirty)
                Button("Delete", role: .destructive) { delete() }
            }
        }
        .alert("Schedule Error", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: {
                let h = startTimeSeconds / 3600
                let m = (startTimeSeconds % 3600) / 60
                return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                startTimeSeconds = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60
            }
        )
    }

    private var draftEvent: ScheduledEvent? {
        guard let id = event.id else { return nil }
        return ScheduledEvent(
            id: id,
            name: name,
            pipelineId: pipelineId,
            daysOfWeek: daysOfWeek,
            startTimeSeconds: startTimeSeconds,
            durationSeconds: durationSeconds,
            isEnabled: isEnabled,
            recordingDirectory: recordingDirectory,
            recordingBookmark: recordingBookmark
        )
    }

    private var isDirty: Bool {
        name               != event.name
        || pipelineId        != event.pipelineId
        || daysOfWeek        != event.daysOfWeek
        || startTimeSeconds  != event.startTimeSeconds
        || durationSeconds   != event.durationSeconds
        || isEnabled         != event.isEnabled
        || recordingDirectory != event.recordingDirectory
        || recordingBookmark != event.recordingBookmark
    }

    private func testConnection() {
        guard AntennaHeadClient.isAntennaHeadRunning else {
            errorMessage = "AntennaHead is not running."
            return
        }
        do {
            let tasks = try AntennaHeadClient.listeningTasks()
            errorMessage = "Connection OK. Active tasks: \(tasks.isEmpty ? "(none)" : tasks.joined(separator: ", "))"
        } catch {
            errorMessage = "Connection failed: \(error)\n\nCheck that AntennaHead is running the newly built binary (with RecS/RecP handlers). Look in AntennaHead's Xcode console for 'registered all 5 AE handlers'."
        }
    }

    private func testRecording() {
        guard recordingDirectory != nil else { return }
        guard let bookmarkB64 = recordingBookmark, let bookmark = Data(base64Encoded: bookmarkB64) else {
            errorMessage = "This folder has no security-scoped bookmark (picked before this was added, or the bookmark failed to save) — click Change… to re-select it."
            return
        }
        let filename = Scheduler.makeRecordingFilename(eventName: name.isEmpty ? "Test" : name)
        do {
            try AntennaHeadClient.startRecording(bookmark: bookmark, filename: filename)
            errorMessage = "Recording started — file will appear as \"\(filename)\" in the chosen folder.\n\nStop AntennaHead's LiveAudioServer recording by stopping the pipeline or waiting for the event to end."
        } catch {
            errorMessage = "Recording test failed: \(error)"
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder for recording files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingDirectory = url.path
        do {
            // AntennaHead (sandboxed) needs this bookmark to gain write access
            // to a folder picked here in unsandboxed ControlBooth — the plain
            // path alone carries no sandbox grant.
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            recordingBookmark = bookmark.base64EncodedString()
        } catch {
            recordingBookmark = nil
            errorMessage = "Couldn't create a security-scoped bookmark for that folder: \(error)\n\nRecording to it will fail until you pick it again."
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        guard let draft = draftEvent else { return }
        do {
            try eventStore.save(draft)
            scheduler.reschedule(events: eventStore.events, pipelineStore: pipelineStore, runner: runner)
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func delete() {
        do {
            try eventStore.delete(event)
            scheduler.reschedule(events: eventStore.events, pipelineStore: pipelineStore, runner: runner)
        } catch {
            errorMessage = "\(error)"
        }
    }
}
