//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import fyyd_swift

struct PodcastSearchView: View {
    @StateObject private var viewModel = PodcastSearchViewModel()
    @Environment(\.modelContext) private var context
    @Binding var search: String

    // Local state for basic auth prompt
    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @FocusState private var focusedField: AuthField?

    private enum AuthField {
        case username
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            if viewModel.isLoading {
                ProgressView()
            }
            else if let singlePodcast = viewModel.singlePodcast{
                SubscribeToPodcastView(newPodcastFeed: singlePodcast)
                    .modelContext(context)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
            } else if !viewModel.searchResults.isEmpty{
                ForEach(viewModel.searchResults, id: \.self) { podcast in
                    SubscribeToPodcastView(newPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                }
                .navigationTitle("Subscribe")
            } else if !viewModel.results.isEmpty{
                ForEach(viewModel.results, id: \.self) { podcast in
                    SubscribeToPodcastView(newPodcastFeed: podcast)
                        .modelContext(context)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(.init(top: 0,
                                             leading: 0,
                                             bottom: 0,
                                             trailing: 0))
                }
                .navigationTitle("Subscribe")
            }
            // Inline authentication form
            else if viewModel.shouldPromptForBasicAuth {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text("Authentication Required")
                            .font(.headline)
                    }

                    if let url = viewModel.pendingURLForAuth {
                        Text(url.host ?? url.absoluteString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Username", text: $authUsername)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .password
                        }

                    SecureField("Password", text: $authPassword)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit {
                            submitAuth()
                        }

                    if let error = viewModel.authErrorMessage, !error.isEmpty {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Cancel") {
                            cancelAuth()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Continue") {
                            submitAuth()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authPassword.isEmpty)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
                .padding(.vertical)
                .onAppear {
                    focusedField = .username
                }
            }
            else if !viewModel.searchText.isEmpty{
                Text("no results for \(search)")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Group{
                    if !viewModel.languages.isEmpty {
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(viewModel.languages, id: \.self) { name in
                                Text(name.languageName()).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        ProgressView("Loading languages...")
                    }
                }
                .padding()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0,
                                     leading: 0,
                                     bottom: 0,
                                     trailing: 0))

                HotPodcastView(viewModel: viewModel)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init(top: 0,
                                         leading: 0,
                                         bottom: 0,
                                         trailing: 0))
            }

            if let url = URL(string: "https://fyyd.de"){
                Link(destination: url) {
                    Label("Search is powered by fyyd", systemImage: "safari")
                }
                .padding()
                .buttonStyle(.glass)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if !viewModel.languages.isEmpty {
                    Picker("Language", selection: $viewModel.selectedLanguage) {
                        ForEach(viewModel.languages, id: \.self) { name in
                            Text(name.languageName()).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    ProgressView("Loading languages...")
                }
            }
        }
        .onChange(of: search) {
            viewModel.searchText = search
        }
    }

    private func submitAuth() {
        let user = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = authPassword
        guard !user.isEmpty, !pass.isEmpty else { return }
        viewModel.submitBasicAuth(username: user, password: pass)
        // Clear for next time
        authUsername = ""
        authPassword = ""
    }

    private func cancelAuth() {
        viewModel.shouldPromptForBasicAuth = false
        authUsername = ""
        authPassword = ""
    }
}

#Preview {
    @Previewable @State var search: String = ""
    PodcastSearchView(search: $search)
}
