import SwiftUI

struct ServerInputView: View {
    @Binding var text: String
    var error: String?
    var placeholder: String
    var providers: [DNSProvider]
    var onValidate: (String) -> Void
    var onCommit: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("Server", text: $text, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, newValue in onValidate(newValue) }
                    .onSubmit { onCommit?() }
                
                Menu {
                    Text("Common Providers")
                    ForEach(providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.variants, id: \.address) { variant in
                                Button("\(variant.protocol) (\(variant.address))") {
                                    text = variant.address
                                    onValidate(variant.address)
                                    onCommit?()
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Select a common DNS provider")
            }
            
            if let error = error {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("IP address or DNS URL")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}
