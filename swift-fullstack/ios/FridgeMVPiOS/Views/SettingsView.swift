import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: PantryViewModel

    @State private var backendURLInput = ""
    @State private var essentialNameInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section("백엔드 연결") {
                    TextField("http://127.0.0.1:8080/", text: $backendURLInput)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)

                    Button("저장 후 재연결") {
                        viewModel.backendURL = backendURLInput
                        viewModel.saveBackendURL()
                        Task { await viewModel.refreshAll() }
                    }
                }

                Section("필수 재료") {
                    HStack {
                        TextField("예: 계란", text: $essentialNameInput)
                        Button("추가") {
                            Task {
                                await viewModel.addEssential(name: essentialNameInput)
                                essentialNameInput = ""
                            }
                        }
                        .disabled(essentialNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(viewModel.essentialItems, id: \.self) { item in
                        HStack {
                            Text(item)
                            Spacer()
                            Button {
                                Task { await viewModel.removeEssential(name: item) }
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section("에러") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("설정")
            .onAppear {
                backendURLInput = viewModel.backendURL
            }
        }
    }
}
