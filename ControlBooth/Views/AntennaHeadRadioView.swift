import AVFoundation
import SwiftUI
import StationKit

/// The AntennaHead Radio tab: start/stop the station, see what it's doing,
/// and edit its settings. Changes save immediately; a running station picks
/// them up when it's stopped and started again.
struct AntennaHeadRadioView: View {
    @Environment(RadioStation.self) private var station

    @State private var playlists: [String] = []
    @State private var airPlayDevices: [String] = []
    @State private var previewText: String?
    @State private var previewing = false
    @State private var voiceTester = AVSpeechSynthesizer()
    @State private var macBrowser = RemoteMacBrowser()
    /// "Another Mac" chosen; kept separately so the host field can be empty while typing.
    @State private var musicFromAnotherMac = false
    @State private var remotePassword = ""
    @State private var connectionResult: (ok: Bool, text: String)?
    @State private var testingConnection = false
    /// The News Feeds box's text as typed. Parsing it into `newsFeeds` drops
    /// blank lines and edge spaces, so the box can't be bound to that list
    /// directly: a new line or a space after "NPR" would vanish as it's typed.
    @State private var newsFeedsText = ""

    var body: some View {
        @Bindable var station = station
        HSplitView {
            Form {
                onAirSection
                stationSection($station.settings)
                musicSection($station.settings)
                announcerSection($station.settings)
                newsWeatherSection($station.settings)
                clockSection($station.settings)
                previewSection
                advancedSection($station.settings)
            }
            .formStyle(.grouped)
            .frame(minWidth: 480)

            logPane
                .frame(minWidth: 260, idealWidth: 340)
        }
        .onAppear {
            musicFromAnotherMac = !(station.settings.musicHost ?? "").isEmpty
            newsFeedsText = station.settings.newsFeeds.joined(separator: "\n")
            loadRemotePassword()
            if musicFromAnotherMac { macBrowser.start() }
            refreshMusicLists()
        }
        .onDisappear { macBrowser.stop() }
    }

    // MARK: On Air

    private var onAirSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(station.statusText)
                    .font(.headline)
                Spacer()
                if station.isOnAir {
                    Button("Skip Song", systemImage: "forward.end.fill") { station.skip() }
                        .disabled(station.director?.canSkip != true)
                        .help("Ring the gong, fade out this song and fade in the next one — or go straight to a news or weather segment that's waiting for the song to end.")
                    Button("Stop", systemImage: "stop.fill") { station.stop() }
                        .disabled(station.director?.phase == .stopping)
                } else {
                    Button("Go On Air", systemImage: "play.fill") { station.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let director = station.director {
                if let song = director.nowPlaying {
                    LabeledContent("Now Playing", value: song)
                }
                if let line = director.lastLine {
                    LabeledContent("Announcer") {
                        Text(line)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("AirPlay Latency", value: String(format: "%.2f s", director.latency))
                if !director.pendingSegments.isEmpty {
                    LabeledContent("Waiting for the Song to End",
                                   value: director.pendingSegments.map(Self.title).joined(separator: ", "))
                }
                HStack {
                    Text("Run Now")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(StationConfig.Segment.allCases) { segment in
                        Button(Self.title(segment)) { station.fire(segment) }
                    }
                }
            }
            if station.needsRestart {
                Label("Settings changed. Stop and go on air again to use them.", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
            if !station.stoppedPipelines.isEmpty, station.isOnAir {
                Text("Stopped \(station.stoppedPipelines.joined(separator: ", ")) to take AntennaHead's input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = station.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("AntennaHead Radio")
        } footer: {
            Text("Plays a Music playlist through ControlBooth's AirPlay receiver to AntennaHead, with an announcer who talks over song endings and reads the news and weather on the hour clock below. While on air the station uses the AirPlay receiver and AntennaHead's ControlBooth input, and gives both back when it stops. For personal use only: Apple Music tracks aren't licensed for rebroadcast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch station.director?.phase {
        case .onAir?, .segment?: return .red
        case .starting?, .stopping?: return .orange
        default: return .secondary
        }
    }

    // MARK: Settings

    private func stationSection(_ s: Binding<StationConfig>) -> some View {
        Section("Station") {
            TextField("Name", text: s.stationName)
            TextField("Slogan", text: s.slogan)
        }
    }

    private func musicSection(_ s: Binding<StationConfig>) -> some View {
        Section {
            Picker("Music Source", selection: Binding(
                get: { musicFromAnotherMac },
                set: { remote in
                    musicFromAnotherMac = remote
                    connectionResult = nil
                    if remote {
                        macBrowser.start()
                    } else {
                        macBrowser.stop()
                        s.wrappedValue.musicHost = nil
                        refreshMusicLists()
                    }
                }
            )) {
                Text("This Mac").tag(false)
                Text("Another Mac").tag(true)
            }
            .pickerStyle(.segmented)

            if musicFromAnotherMac {
                remoteMusicFields(s)
            }

            HStack {
                Button(testingConnection ? "Connecting…" : "Test Connection") { testConnection() }
                    .disabled(testingConnection || (musicFromAnotherMac && (s.wrappedValue.musicHost ?? "").isEmpty))
                if let connectionResult {
                    Label(connectionResult.text, systemImage: connectionResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(connectionResult.ok ? .green : .red)
                        .textSelection(.enabled)
                }
            }

            Picker("Playlist", selection: s.playlist) {
                ForEach(Self.including(s.wrappedValue.playlist, in: playlists), id: \.self) { Text($0) }
            }
            Toggle("Shuffle", isOn: s.shuffle)
            Picker("AirPlay Device", selection: s.airPlayDeviceName) {
                ForEach(Self.including(s.wrappedValue.airPlayDeviceName, in: airPlayDevices), id: \.self) { Text($0) }
            }
        } header: {
            HStack {
                Text("Music")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshMusicLists)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Reload playlists and AirPlay devices from Music")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The AirPlay device is ControlBooth's own receiver (its Device Name on the AirPlay Receiver tab). Only playlists with tracks are listed.")
                if musicFromAnotherMac {
                    Text("On the other Mac: turn on System Settings › General › Sharing › Remote Application Scripting, keep Music (or iTunes) open, and make sure it can see \"\(s.wrappedValue.airPlayDeviceName)\" as an AirPlay speaker. The music still reaches the station over AirPlay. The password is kept in this Mac's Keychain.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func remoteMusicFields(_ s: Binding<StationConfig>) -> some View {
        let host = Binding(get: { s.wrappedValue.musicHost ?? "" },
                           set: { s.wrappedValue.musicHost = $0.trimmingCharacters(in: .whitespaces); loadRemotePassword() })
        let user = Binding(get: { s.wrappedValue.musicHostUser ?? "" },
                           set: { s.wrappedValue.musicHostUser = $0; loadRemotePassword() })
        Picker("Mac", selection: host) {
            if macBrowser.macs.isEmpty {
                Text(macBrowser.isBrowsing ? "Looking for Macs…" : "None Found").tag(host.wrappedValue)
            } else if !macBrowser.macs.contains(where: { $0.host == host.wrappedValue }) {
                Text(host.wrappedValue.isEmpty ? "Choose a Mac" : host.wrappedValue).tag(host.wrappedValue)
            }
            ForEach(macBrowser.macs) { mac in
                Text(mac.name).tag(mac.host)
            }
        }
        .help("Macs on this network with Remote Application Scripting turned on")
        TextField("Host Name or Address", text: host, prompt: Text("Studio-Mac.local"))
        TextField("User Name", text: user, prompt: Text("an account on that Mac"))
        SecureField("Password", text: $remotePassword)
            .onChange(of: remotePassword) { _, password in
                guard let h = s.wrappedValue.musicHost, !h.isEmpty,
                      let u = s.wrappedValue.musicHostUser, !u.isEmpty else { return }
                RemoteMusicCredentials.setPassword(password, user: u, host: h)
            }
        Picker("App", selection: Binding(get: { s.wrappedValue.musicApp ?? "Music" },
                                         set: { s.wrappedValue.musicApp = $0 })) {
            Text("Music").tag("Music")
            Text("iTunes (older Macs)").tag("iTunes")
        }
    }

    private func announcerSection(_ s: Binding<StationConfig>) -> some View {
        Section("Announcer") {
            HStack {
                Picker("Voice", selection: s.voice) {
                    Text("System Default").tag(String?.none)
                    ForEach(Self.voices, id: \.identifier) { voice in
                        Text(Self.voiceLabel(voice)).tag(Optional(voice.identifier))
                    }
                }
                Button("Try", systemImage: "speaker.wave.2") { tryVoice(s.wrappedValue) }
                    .labelStyle(.iconOnly)
                    .help("Hear this voice on this Mac")
            }
            Stepper(value: s.talkOverEvery, in: 0...10) {
                LabeledContent("Talk Over Song Endings",
                               value: s.wrappedValue.talkOverEvery == 0 ? "Never"
                                   : s.wrappedValue.talkOverEvery == 1 ? "Every Song"
                                   : "Every \(s.wrappedValue.talkOverEvery) Songs")
            }
            Toggle(isOn: s.useAI) {
                Text("Write Lines with Apple Intelligence")
                Text("The on-device model varies the wording, using only the song, time and weather facts. A line that mentions anything else is replaced by a plain one.")
            }
        }
    }

    private func newsWeatherSection(_ s: Binding<StationConfig>) -> some View {
        Section {
            HStack {
                TextField("Latitude", value: s.latitude, format: .number.precision(.fractionLength(0...4)))
                TextField("Longitude", value: s.longitude, format: .number.precision(.fractionLength(0...4)))
            }
            Stepper(value: s.headlineCount, in: 0...8) {
                LabeledContent("Headlines at the Top of the Hour", value: "\(s.wrappedValue.headlineCount)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("News Feeds (RSS or Atom, one per line; put the name to credit first: NPR | https://…)")
                TextEditor(text: $newsFeedsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .onChange(of: newsFeedsText) { _, text in
                        s.wrappedValue.newsFeeds = text.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }
        } header: {
            Text("News & Weather")
        } footer: {
            Text("Weather is from the National Weather Service (U.S. locations only).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func clockSection(_ s: Binding<StationConfig>) -> some View {
        Section {
            ForEach(s.clock.indices, id: \.self) { index in
                HStack {
                    Stepper(value: s.clock[index].minute, in: 0...59) {
                        Text(String(format: ":%02d", s.wrappedValue.clock[index].minute))
                            .monospacedDigit()
                    }
                    .fixedSize()
                    Picker("", selection: s.clock[index].segment) {
                        ForEach(StationConfig.Segment.allCases) { Text(Self.title($0)).tag($0) }
                    }
                    .labelsHidden()
                    Button("Remove", systemImage: "minus.circle") { s.wrappedValue.clock.remove(at: index) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Event", systemImage: "plus") {
                s.wrappedValue.clock.append(.init(minute: 15, segment: .stationID))
            }
        } header: {
            Text("Hour Clock")
        } footer: {
            Text("Every hour. Top of Hour and Weather wait for the song playing at that minute to end, then mute the music while they're read. A Station ID is spoken over the end of that song.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Button(previewing ? "Writing…" : "Preview This Hour's Lines") {
                previewing = true
                Task {
                    previewText = await station.preview()
                    previewing = false
                }
            }
            .disabled(previewing)
            if let previewText {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func advancedSection(_ s: Binding<StationConfig>) -> some View {
        Section("Advanced") {
            DisclosureGroup("Timing, Ducking and Ports") {
                LabeledContent("Speech Ends Before Song End") {
                    TextField("", value: s.talkOverEndGapSeconds, format: .number).frame(width: 60)
                    Text("s")
                }
                LabeledContent("Longest Wait for a Song to End") {
                    TextField("", value: s.maxSegmentWaitSeconds, format: .number).frame(width: 60)
                    Text("s")
                }
                LabeledContent("Music Level Under the Voice") {
                    TextField("", value: s.duck.attenuation, format: .number).frame(width: 60)
                    Text("× (0.25 ≈ −12 dB)")
                }
                LabeledContent("Music In / Announcer / Mixer Control") {
                    TextField("", value: s.ports.musicIn, format: .number.grouping(.never)).frame(width: 60)
                    TextField("", value: s.ports.announcerIn, format: .number.grouping(.never)).frame(width: 60)
                    TextField("", value: s.ports.mixerControl, format: .number.grouping(.never)).frame(width: 60)
                }
                LabeledContent("AntennaHead Input Port") {
                    TextField("", value: s.ports.antennaHead, format: .number.grouping(.never)).frame(width: 60)
                }
                LabeledContent("Source Name in AntennaHead") {
                    TextField("", text: s.antennaHeadSourceName).frame(width: 180)
                }
                Button("Restore Defaults", role: .destructive) {
                    s.wrappedValue = .defaults
                    newsFeedsText = StationConfig.defaults.newsFeeds.joined(separator: "\n")
                }
            }
        }
    }

    // MARK: Log

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Station Log")
                .font(.headline)
                .padding(8)
            Divider()
            ScrollViewReader { proxy in
                List(station.log) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.date, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .id(line.id)
                }
                .onChange(of: station.log.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Helpers

    private func refreshMusicLists() {
        let music = MusicPlayer(target: station.musicTarget())
        // A remote Mac that isn't answering would just give empty lists.
        if music.target.isRemote, (try? music.testConnection()) == nil { return }
        playlists = music.playlistNames()
        airPlayDevices = music.airPlayDeviceNames()
    }

    private func testConnection() {
        testingConnection = true
        connectionResult = nil
        // Let the button show "Connecting…" before the (blocking) Apple Event.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            do {
                let text = try MusicPlayer(target: station.musicTarget()).testConnection()
                connectionResult = (true, text)
                refreshMusicLists()
            } catch {
                connectionResult = (false, "\(error)")
            }
            testingConnection = false
        }
    }

    private func loadRemotePassword() {
        let settings = station.settings
        guard let host = settings.musicHost, !host.isEmpty,
              let user = settings.musicHostUser, !user.isEmpty else {
            if !remotePassword.isEmpty { remotePassword = "" }
            return
        }
        let saved = RemoteMusicCredentials.password(user: user, host: host) ?? ""
        if saved != remotePassword { remotePassword = saved }
    }

    private func tryVoice(_ config: StationConfig) {
        voiceTester.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "You're listening to \(config.stationName), \(config.slogan).")
        if let id = config.voice { utterance.voice = AVSpeechSynthesisVoice(identifier: id) }
        voiceTester.speak(utterance)
    }

    /// `list`, with `value` added if it isn't there (a saved choice Music
    /// doesn't currently show must stay selectable).
    private static func including(_ value: String, in list: [String]) -> [String] {
        list.contains(value) || value.isEmpty ? list : [value] + list
    }

    nonisolated static func title(_ segment: StationConfig.Segment) -> String {
        switch segment {
        case .topOfHour: return "Top of Hour"
        case .weather: return "Weather"
        case .stationID: return "Station ID"
        }
    }

    /// English voices worth announcing with: Apple's modern voices (and any
    /// Personal Voice), best quality first — not the novelty voices.
    private static let voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") && ($0.identifier.hasPrefix("com.apple.voice.") || $0.voiceTraits.contains(.isPersonalVoice)) }
        .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }

    private static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        // Names already carry the quality ("Ava (Premium)").
        "\(voice.name), \(voice.language)"
    }
}
