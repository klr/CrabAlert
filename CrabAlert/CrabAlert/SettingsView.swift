//
//  SettingsView.swift
//  CrabAlert
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: EndpointStore

    @State private var selection = Set<Endpoint.ID>()
    @State private var newName = ""
    @State private var newURL = ""
    @State private var errorMessage: String?

    private var removableSelection: Set<Endpoint.ID> {
        selection.subtracting([Endpoint.defaultID])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MailCrab Endpoints")
                .font(.headline)

            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.all) { endpoint in
                        EndpointRow(endpoint: endpoint)
                            .tag(endpoint.id)
                            .selectionDisabled(endpoint.isDefault)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 160)
                .contextMenu(forSelectionType: Endpoint.ID.self) { ids in
                    let removable = ids.subtracting([Endpoint.defaultID])
                    Button("Remove") { remove(removable) }
                        .disabled(removable.isEmpty)
                }
                .onDeleteCommand { remove(removableSelection) }

                HStack {
                    Button {
                        remove(removableSelection)
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(removableSelection.isEmpty)
                    .help("Remove selected endpoint")

                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Divider()

            Text("Add Endpoint")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Name:")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $newName, prompt: Text("Staging"))
                        .labelsHidden()
                }
                GridRow {
                    Text("URL:")
                    TextField("URL", text: $newURL, prompt: Text("http://localhost:1081"))
                        .labelsHidden()
                        .onSubmit(add)
                }
            }

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty ||
                              newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: newName) { errorMessage = nil }
        .onChange(of: newURL) { errorMessage = nil }
    }

    private func add() {
        if let error = store.add(name: newName, urlString: newURL) {
            errorMessage = error
        } else {
            newName = ""
            newURL = ""
            errorMessage = nil
        }
    }

    private func remove(_ ids: Set<Endpoint.ID>) {
        guard !ids.isEmpty else { return }
        store.remove(ids: ids)
        selection.subtract(ids)
    }
}

private struct EndpointRow: View {
    let endpoint: Endpoint

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name)
                    .fontWeight(.semibold)
                Text(endpoint.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if endpoint.isDefault {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("The default endpoint is always monitored")
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SettingsView(store: EndpointStore(defaults: UserDefaults(suiteName: "preview")!))
}
