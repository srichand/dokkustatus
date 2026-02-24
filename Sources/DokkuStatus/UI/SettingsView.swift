import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StatusStore

    private let customProfileSelectionID = "__custom_profile__"

    @State private var host = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var sshAlias = ""
    @State private var selectedProfileID = "__custom_profile__"
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var isApplyingSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dokku Host")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Picker("Profile", selection: $selectedProfileID) {
                    ForEach(store.availableProfiles) { option in
                        Text(option.menuTitle).tag(option.id)
                    }

                    Text("Custom Override").tag(customProfileSelectionID)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedProfileID) { _, newValue in
                    guard !isApplyingSelection else {
                        return
                    }

                    applyProfileSelection(newValue)
                }

                if let selected = store.availableProfiles.first(where: { $0.id == selectedProfileID }) {
                    Text(selected.config.displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Edit fields below to create a custom override profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)

                TextField("User", text: $user)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)

                TextField("SSH Alias (optional)", text: $sshAlias)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            Text("If SSH Alias is set, it will be used instead of user@host.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)

                Button("Remove Saved Profile") {
                    store.clearHostConfig()
                    store.reloadProfileOptions()
                    loadFromStore()
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard !didLoad else {
                return
            }

            didLoad = true
            store.reloadProfileOptions()
            loadFromStore()
        }
        .onChange(of: store.hostConfig) { _, _ in
            guard didLoad else {
                return
            }

            loadFromStore()
        }
        .onChange(of: store.availableProfiles) { _, _ in
            guard didLoad else {
                return
            }

            syncSelectedProfile()
        }
    }

    private func loadFromStore() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        if let config = store.hostConfig {
            host = config.host
            user = config.user
            port = String(config.port)
            sshAlias = config.sshAlias ?? ""
        } else {
            host = ""
            user = ""
            port = "22"
            sshAlias = ""
        }

        syncSelectedProfile()
        errorMessage = nil
    }

    private func save() {
        errorMessage = store.saveHostConfig(
            host: host,
            user: user,
            portText: port,
            sshAlias: sshAlias
        )

        if errorMessage == nil {
            store.reloadProfileOptions()
            loadFromStore()
        }
    }

    private func applyProfileSelection(_ selectionID: String) {
        guard selectionID != customProfileSelectionID else {
            return
        }

        store.activateHostProfile(optionID: selectionID)
        loadFromStore()
    }

    private func syncSelectedProfile() {
        let targetSelection = store.activeProfileOptionID ?? customProfileSelectionID
        if selectedProfileID != targetSelection {
            selectedProfileID = targetSelection
        }
    }
}
