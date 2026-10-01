//
//  PodcastSearchView.swift
//  Raul
//
//  Created by Holger Krupp on 02.04.25.
//

import SwiftUI
import SwiftData

struct PodcastSearchView: View {
    @StateObject private var viewModel: PodcastSearchViewModel
    @Environment(\.modelContext) private var context
    @Binding var search: String

    // Local state for basic auth prompt
    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @State private var authBearerToken: String = ""
    @FocusState private var focusedField: AuthField?

    private enum AuthField {
        case username
        case password
    }

    init(search: Binding<String>, treatsDirectURLsAsPrivate: Bool = false) {
        _search = search
        _viewModel = StateObject(
            wrappedValue: PodcastSearchViewModel(
                treatsDirectURLsAsPrivate: treatsDirectURLsAsPrivate
            )
        )
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
                .onAppear {
                    viewModel.searchText = search
                }
                .onChange(of: search) {
                    viewModel.searchText = search
                }

            if viewModel.isLoading {
                if viewModel.isDirectURLInput {
                    Label("Add Podcast from URL", systemImage: "link")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
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
            else if viewModel.shouldPromptForBasicAuth || viewModel.shouldPromptForBearerToken {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text(viewModel.shouldPromptForBearerToken ? "Bearer Token Required" : "Authentication Required")
                            .font(.headline)
                    }

                    if let url = viewModel.pendingURLForAuth {
                        Text(url.host ?? url.redactedPodcastURLString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.shouldPromptForBearerToken {
                        SecureField("Bearer token", text: $authBearerToken)
                            .textContentType(.password)
                            .onSubmit { submitAuth() }
                    } else {
                        TextField("Username", text: $authUsername)
                            .disableAutocorrection(true)
                            .textContentType(.username)
                            .focused($focusedField, equals: .username)
                            .onSubmit {
                                focusedField = .password
                            }

                        SecureField("Password", text: $authPassword)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .onSubmit {
                                submitAuth()
                            }
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
                        .disabled(viewModel.shouldPromptForBearerToken
                                  ? authBearerToken.isEmpty
                                  : authUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authPassword.isEmpty)
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
            else if let urlErrorMessage = viewModel.urlErrorMessage {
                Label("Couldn’t add podcast from URL", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(urlErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            else if !viewModel.searchText.isEmpty{
                Text("no results for \(search)")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .onDisappear {
            viewModel.cancelPendingSearch()
        }
    }

    private func submitAuth() {
        let user = authUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = authPassword
        if viewModel.shouldPromptForBearerToken {
            guard authBearerToken.isEmpty == false else { return }
            viewModel.submitBearerToken(authBearerToken)
        } else {
            guard !user.isEmpty, !pass.isEmpty else { return }
            viewModel.submitBasicAuth(username: user, password: pass)
        }
        // Clear for next time
        authUsername = ""
        authPassword = ""
        authBearerToken = ""
    }

    private func cancelAuth() {
        viewModel.shouldPromptForBasicAuth = false
        authUsername = ""
        authPassword = ""
        authBearerToken = ""
    }
}

#Preview {
    @Previewable @State var search: String = ""
    PodcastSearchView(search: $search)
}
