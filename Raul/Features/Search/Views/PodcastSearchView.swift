//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI

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
        Group {
            // Invisible anchor row carrying the search sync, so the result
            // rows below stay as individual (lazy) List rows.
            Color.clear
                .frame(height: 0)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .onChange(of: search) {
                    viewModel.searchText = search
                }

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
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .username)
                        .onSubmit {
                            focusedField = .password
                        }

                    SecureField("Password", text: $authPassword)
                        .focused($focusedField, equals: .password)
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
            }
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
