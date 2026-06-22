import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                Section("服务器") {
                    if let session = store.session {
                        LabeledContent("地址", value: session.serverURL.absoluteString)
                        LabeledContent("用户", value: session.username)
                        LabeledContent("歌曲", value: "\(store.songs.count)")
                        LabeledContent("歌单", value: "\(store.playlists.count)")
                        Text(store.libraryStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await store.refreshLibrary() }
                    } label: {
                        Label("刷新资料库", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.session == nil || store.isLoading)
                }

                Section {
                    Button(role: .destructive) {
                        store.signOut()
                    } label: {
                        Label("断开连接", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(store.session == nil)
                }
            }
            .scrollContentBackground(.hidden)
            .mainPageToolbar("设置")
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var store: AppStore
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器地址", text: $server)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                    SecureField("密码", text: $password)
                } footer: {
                    Text("示例：http://192.168.1.10:8096")
                }

                if let error = store.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await store.signIn(server: server, username: username, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isLoading {
                                ProgressView()
                            } else {
                                Text("连接")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(server.isEmpty || username.isEmpty || password.isEmpty || store.isLoading)
                }
            }
            .navigationTitle("连接 Emby")
        }
        .presentationBackground(.regularMaterial)
    }
}
