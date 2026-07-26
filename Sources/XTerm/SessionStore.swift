import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [SerialSession] = [] {
        didSet { scheduleSave() }
    }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedSessionID") }
    }

    private var saveWork: DispatchWorkItem?
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("sessions.json")
        load()
    }

    func add() {
        var session = SerialSession()
        session.name = "会话 \(sessions.count + 1)"
        sessions.append(session)
        selectedID = session.id
    }

    func duplicate(_ id: UUID) {
        guard var copy = sessions.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " 副本"
        sessions.append(copy)
        selectedID = copy.id
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = sessions.first?.id }
        if sessions.isEmpty { add() }
    }

    func update(_ session: SerialSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SerialSession].self, from: data),
           !decoded.isEmpty {
            sessions = decoded.map { session in
                var restored = session
                for index in restored.loginSteps.indices where restored.loginSteps[index].secret {
                    let key = SecureStore.key(sessionID: restored.id, stepID: restored.loginSteps[index].id)
                    restored.loginSteps[index].send = SecureStore.load(key: key) ?? ""
                }
                return restored
            }
        } else {
            sessions = [SerialSession()]
        }
        if let saved = UserDefaults.standard.string(forKey: "selectedSessionID").flatMap(UUID.init),
           sessions.contains(where: { $0.id == saved }) {
            selectedID = saved
        } else {
            selectedID = sessions.first?.id
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        var snapshot = sessions
        for sessionIndex in snapshot.indices {
            for stepIndex in snapshot[sessionIndex].loginSteps.indices
            where snapshot[sessionIndex].loginSteps[stepIndex].secret {
                let step = snapshot[sessionIndex].loginSteps[stepIndex]
                let key = SecureStore.key(sessionID: snapshot[sessionIndex].id, stepID: step.id)
                if !step.send.isEmpty { SecureStore.save(step.send, key: key) }
                snapshot[sessionIndex].loginSteps[stepIndex].send = ""
            }
        }
        let url = fileURL
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder.pretty.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
