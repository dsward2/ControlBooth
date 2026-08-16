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
    @State private var isRecordingEnabled: Bool
    @State private var recordingOnly: Bool
    @State private var errorMessage: String?

    private static let dayAbbreviations = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(event: ScheduledEvent) {
        self.event = event
        _name               = State(initialValue: event.name)
        _pipelineId         = State(initialValue: event.pipelineId)
        _daysOfWeek         = State(initialValue: event.daysOfWeek)
        _startTimeSeconds   = State(initialValue: event.startTimeSeconds)
        _durationSeconds    = State(initialValue: event.durationSeconds)
        _isEnabled          = State(initialValue: event.isEnabled)
        _isRecordingEnabled = State(initialValue: event.isRecordingEnabled)
        _recordingOnly      = State(initialValue: event.recordingOnly)
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

            Section {
                Toggle("Record this event", isOn: $isRecordingEnabled)
                if isRecordingEnabled {
                    Picker("Mode", selection: $recordingOnly) {
                        Text("Recording with Playback").tag(false)
                        Text("Recording Only").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if recordingOnly {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                            Text("No live playback through AntennaHead — this pipeline records straight to a local AAC file and never contends with other pipelines for AntennaHead's UDP input port, so it can run concurrently with anything else.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("Test Connection") { testConnection() }
                                .help("Sends a 'Runs' query to AntennaHead to verify the Apple Event channel works")
                            Button("Test Recording Now") { testRecording() }
                                .help("Immediately starts a recording in AntennaHead's configured recording folder")
                            Button("Stop Test Recording") { testStopRecording() }
                                .help("Stops the recording started by Test Recording Now and moves the finished file to its destination")
                        }
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text(recordingOnly
                     ? "Recording-only files are written to the same shared Recordings folder AntennaHead uses, named from this event's name and the run's start time — no AntennaHead connection required, and no live audio playback happens."
                     : "This pipeline streams to AntennaHead over UDP for live playback; recordings are written to the folder configured in AntennaHead's own Settings (Configuration → Recording) — not picked here, since AntennaHead is sandboxed and can't be granted access to a folder chosen in this, unsandboxed, app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            isRecordingEnabled: isRecordingEnabled,
            recordingOnly: recordingOnly
        )
    }

    private var isDirty: Bool {
        name                != event.name
        || pipelineId         != event.pipelineId
        || daysOfWeek         != event.daysOfWeek
        || startTimeSeconds   != event.startTimeSeconds
        || durationSeconds    != event.durationSeconds
        || isEnabled          != event.isEnabled
        || isRecordingEnabled != event.isRecordingEnabled
        || recordingOnly      != event.recordingOnly
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
        let filename = Scheduler.makeRecordingFilename(eventName: name.isEmpty ? "Test" : name)
        do {
            try AntennaHeadClient.startRecording(filename: filename, useToneFiller: true)
            errorMessage = "Recording started — you should hear a test tone in the recording once no live audio is present. File will appear as \"\(filename)\" in AntennaHead's configured recording folder once you click Stop Test Recording."
        } catch {
            errorMessage = "Recording test failed: \(error)"
        }
    }

    private func testStopRecording() {
        do {
            try AntennaHeadClient.stopRecording()
            errorMessage = "Recording stopped — the finished file should now appear in AntennaHead's configured recording folder."
        } catch {
            errorMessage = "Recording stop failed: \(error)"
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
