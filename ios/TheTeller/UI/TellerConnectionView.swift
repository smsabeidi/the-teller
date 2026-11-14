import SwiftUI

struct TellerConnectionView: View {
    let connection: TellerConnection
    let save: (TellerConnection) -> Void
    @State private var address = ""
    @State private var key = ""
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("HTTPS server address", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("server-address")
                SecureField("Server key", text: $key)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("server-key")
            } header: {
                Text("Personal server")
            } footer: {
                Text("Enter the address and key from your Teller server. Your connection is saved on this device.")
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    if checking {
                        ProgressView("Checking server…")
                    } else {
                        Text("Test and save")
                    }
                }
                .accessibilityIdentifier("server-save")
                .disabled(checking)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .accessibilityIdentifier("server-status")
                }
            }
        }
        .navigationTitle("Connection")
        .onAppear {
            if address.isEmpty {
                address = connection.baseURL.host == "the-teller.invalid" ? "" : connection.baseURL.absoluteString
                key = connection.accessKey ?? ""
            }
        }
    }

    @MainActor
    private func connect() async {
        checking = true
        message = nil
        defer { checking = false }
        do {
            let candidate = try TellerConnection.supplied(address: address, key: key)
            try await TellerAPI(baseURL: candidate.baseURL, accessKey: candidate.accessKey).checkConnection()
            try candidate.save()
            message = "Connected."
            save(candidate)
        } catch {
            message = error.localizedDescription
        }
    }
}
