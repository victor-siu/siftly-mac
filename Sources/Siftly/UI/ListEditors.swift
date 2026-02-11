import SwiftUI

struct DNSListEditor: View {
    @Binding var list: [String]
    @State private var text: String
    
    init(list: Binding<[String]>) {
        _list = list
        _text = State(initialValue: list.wrappedValue.joined(separator: "\n"))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .onChange(of: text) { _, newValue in
                    list = newValue.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
            
            Divider()
            
            HStack {
                Spacer()
                Menu {
                    Text("Add Common Provider")
                    ForEach(commonDNSProviders) { provider in
                        Menu(provider.name) {
                            ForEach(provider.variants, id: \.address) { variant in
                                Button("\(variant.protocol) (\(variant.address))") {
                                    appendServer(variant.address)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Add Common", systemImage: "plus.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .padding(4)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
    
    private func appendServer(_ server: String) {
        if text.isEmpty {
            text = server
        } else {
            if !text.hasSuffix("\n") {
                text += "\n"
            }
            text += server
        }
    }
}

struct StringListEditor: View {
    @Binding var list: [String]
    @State private var text: String
    
    init(list: Binding<[String]>) {
        _list = list
        _text = State(initialValue: list.wrappedValue.joined(separator: "\n"))
    }
    
    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .onChange(of: text) { _, newValue in
                list = newValue.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
    }
}

struct IntListEditor: View {
    @Binding var list: [Int]
    @State private var text: String
    
    init(list: Binding<[Int]>) {
        _list = list
        _text = State(initialValue: list.wrappedValue.map(String.init).joined(separator: ", "))
    }
    
    var body: some View {
        TextField("Ports (comma separated)", text: $text)
            .textFieldStyle(.roundedBorder)
            .onChange(of: text) { _, newValue in
                list = newValue.components(separatedBy: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
    }
}
