import SwiftUI

/// Adds an account on a MapQuest server (PostgreSQL behind Server/mapquest_server.py).
struct AddRemoteSourceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = "https://"
    @State private var token = ""
    @State private var records = false
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Access token", text: $token)
            } footer: {
                Text("The token identifies your account on the server (created with `mapquest_server.py add-user`). It is stored in the Keychain.")
            }
            Section {
                Toggle("Record my positions into this account", isOn: $records)
            } footer: {
                Text("Off: view the account's discoveries only (e.g. a friend's). On: this iPhone adds its positions – requires a network connection.")
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    Task { await add() }
                } label: {
                    if isChecking { ProgressView() } else { Text("Connect") }
                }
                .disabled(isChecking || URL(string: url)?.host == nil || token.isEmpty)
            }
        }
        .navigationTitle("Remote data source")
    }

    private func add() async {
        guard let serverURL = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            try await model.addRemoteDataSource(url: serverURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines), records: records)
            dismiss()
        } catch {
            self.error = "Could not connect: \(error.localizedDescription)"
        }
    }
}
