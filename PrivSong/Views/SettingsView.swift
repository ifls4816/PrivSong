import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                Section("资料库") {
                    libraryRows
                }

                Section("播放与启动") {
                    playbackRows
                }

                Section {
                    storageRows
                } header: {
                    Text("存储")
                } footer: {
                    Text("播放过的歌曲会缓存到本机，再次播放时无需联网。超过上限后自动删除最久未播放的歌曲。")
                }

                Section("高级") {
                    advancedRows
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.musicPageBackground.ignoresSafeArea())
            .safeAreaPadding(.bottom, 112)
            .mainPageToolbar("设置")
            .navigationBarBackButtonHidden(true)
            .task {
                await store.refreshCacheUsage()
            }
        }
    }

    private var libraryRows: some View {
        Group {
            NavigationLink {
                EditLibrarySettingsView()
            } label: {
                SettingsValueRow(
                    title: "编辑资料库",
                    value: librarySummary,
                    icon: "music.note.list",
                    tint: .blue
                )
            }

            Button {
                Task { await store.refreshLibrary() }
            } label: {
                SettingsActionRow(title: "刷新资料库", icon: "arrow.clockwise", tint: .musicRed, showsProgress: store.isLoading)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil || store.isLoading)
        }
    }

    private var storageRows: some View {
        Group {
            AudioCacheLimitMenuRow(selection: $store.audioCacheLimit)

            Button {
                store.clearCaches()
            } label: {
                SettingsActionRow(
                    title: "清除缓存",
                    icon: "trash",
                    tint: .orange,
                    showsProgress: store.isClearingCache,
                    value: cacheUsageSummary
                )
            }
            .buttonStyle(.plain)
            .disabled(store.isClearingCache)
        }
    }

    private var cacheUsageSummary: String? {
        guard !store.isClearingCache, let bytes = store.cacheUsageBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var librarySummary: String {
        store.songs.isEmpty ? "暂无歌曲" : "\(store.songs.count) 首歌曲"
    }

    private var playbackRows: some View {
        Group {
            NavigationLink {
                PlaybackQualitySettingsView()
            } label: {
                SettingsValueRow(
                    title: "播放音质",
                    value: store.playbackQualitySummary,
                    icon: "dot.radiowaves.left.and.right",
                    tint: .musicRed
                )
            }

            SettingsToggleRow(
                title: "发现页作为首页",
                icon: "safari",
                tint: .blue,
                isOn: $store.startsOnBrowse
            )

            SettingsToggleRow(
                title: "播放页屏幕常亮",
                icon: "sun.max",
                tint: .orange,
                isOn: $store.keepsScreenAwakeOnPlayerPage
            )
        }
    }

    private var advancedRows: some View {
        Group {
            SettingsToggleRow(
                title: "120Hz 高刷新率",
                icon: "speedometer",
                tint: .purple,
                isOn: $store.prefersHighRefreshRate
            )
        }
    }
}

private struct EditLibrarySettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSignOutConfirmationPresented = false

    private var canSubmitConnectionChanges: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !store.isLoading
    }

    var body: some View {
        Form {
            Section {
                TextField("服务器", text: $server)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                TextField("用户", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("密码", text: $password)
            } header: {
                Text("连接信息")
            } footer: {
                Text("修改连接信息需要重新输入密码并重新连接 Emby。")
            }

            Section {
                Button {
                    Task {
                        await store.signIn(server: server, username: username, password: password)
                        if store.errorMessage == nil {
                            password = ""
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if store.isLoading {
                            ProgressView()
                        } else {
                            Text("保存并重新连接")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSubmitConnectionChanges)
            }

            if let errorMessage = store.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("当前资料库") {
                SettingsInfoRow(title: "歌曲", value: "\(store.songs.count) 首")
                SettingsInfoRow(title: "专辑", value: "\(store.albums.count) 张")
                SettingsInfoRow(title: "艺术家", value: "\(store.artists.count) 位")
                SettingsInfoRow(title: "状态", value: store.localizedLibraryStatus)
            }

            Section {
                Button(role: .destructive) {
                    isSignOutConfirmationPresented = true
                } label: {
                    HStack {
                        Spacer()
                        Text("断开连接")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(store.session == nil)
                .confirmationDialog("断开 Emby 连接？", isPresented: $isSignOutConfirmationPresented, titleVisibility: .visible) {
                    Button("断开连接", role: .destructive) {
                        store.signOut()
                        password = ""
                    }

                    Button("取消", role: .cancel) {}
                } message: {
                    Text("断开后会清除本地资料库快照和封面缓存，需要重新连接 Emby。")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .navigationTitle("编辑资料库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConnectionFields)
        .onChange(of: store.session) { _, _ in
            loadConnectionFields()
        }
    }

    private func loadConnectionFields() {
        guard let session = store.session else {
            server = ""
            username = ""
            return
        }
        server = session.serverURL.absoluteString
        username = session.username
    }
}

private struct PlaybackQualitySettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section {
                PlaybackQualityMenuRow(
                    title: "移动网络音质",
                    icon: "antenna.radiowaves.left.and.right",
                    tint: .orange,
                    selection: $store.cellularOnlineQuality
                )

                PlaybackQualityMenuRow(
                    title: "Wi-Fi 音质",
                    icon: "wifi",
                    tint: .blue,
                    selection: $store.wifiOnlineQuality
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.musicPageBackground.ignoresSafeArea())
        .navigationTitle("播放音质")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaybackQualityMenuRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var selection: OnlinePlaybackQuality

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, tint: tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Menu {
                ForEach(OnlinePlaybackQuality.allCases) { quality in
                    Button {
                        selection = quality
                    } label: {
                        if selection == quality {
                            Label(quality.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(quality.displayTitle)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.displayTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.blue)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
    }
}

private struct AudioCacheLimitMenuRow: View {
    @Binding var selection: AudioCacheLimit

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: "internaldrive", tint: .gray)
            Text("歌曲缓存上限")
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Menu {
                ForEach(AudioCacheLimit.allCases) { limit in
                    Button {
                        selection = limit
                    } label: {
                        if selection == limit {
                            Label(limit.title, systemImage: "checkmark")
                        } else {
                            Text(limit.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.title)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.blue)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, tint: tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let icon: String
    let tint: Color
    var showsProgress = false
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, tint: tint)
            Text(title)
                .foregroundStyle(tint == .red ? Color.red : Color.primary)
            Spacer(minLength: 8)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                SettingsIcon(icon: icon, tint: tint)
                Text(title)
                    .foregroundStyle(.primary)
            }
        }
        .toggleStyle(.switch)
        .tint(.musicRed)
    }
}

private struct SettingsIcon: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SignInView: View {
    @EnvironmentObject private var store: AppStore
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    private var canConnect: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !store.isLoading
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SignInBackground()

                ScrollView {
                    VStack(spacing: 24) {
                        SignInHeader()

                        VStack(spacing: 0) {
                            SignInInputRow(
                                title: "服务器",
                                placeholder: "http://192.168.x.x:8080",
                                icon: "server.rack",
                                tint: .blue,
                                kind: .server,
                                text: $server
                            )

                            Divider()
                                .padding(.leading, 68)

                            SignInInputRow(
                                title: "用户",
                                placeholder: "Emby 用户名",
                                icon: "person.fill",
                                tint: .musicRed,
                                kind: .username,
                                text: $username
                            )

                            Divider()
                                .padding(.leading, 68)

                            SignInInputRow(
                                title: "密码",
                                placeholder: "Emby 密码",
                                icon: "lock.fill",
                                tint: .orange,
                                kind: .password,
                                text: $password
                            )
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 22, y: 14)

                        if let error = store.errorMessage {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                Text(error)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        Button {
                            Task { await store.signIn(server: server, username: username, password: password) }
                        } label: {
                            HStack(spacing: 10) {
                                if store.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                }

                                Text(store.isLoading ? "连接中..." : "连接 Emby")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .foregroundStyle(canConnect || store.isLoading ? .white : .secondary)
                            .background(
                                canConnect || store.isLoading ? Color.musicRed : Color.secondary.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.musicRed)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("支持局域网地址或 HTTPS 域名")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("连接成功后会自动同步资料库，并优先使用本地缓存启动。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 34)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("连接 Emby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationBackground(.regularMaterial)
    }
}

private struct SignInBackground: View {
    var body: some View {
        ZStack {
            Color.musicPageBackground

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.musicRed.opacity(0.28),
                        Color(red: 1.0, green: 0.38, blue: 0.30).opacity(0.14),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 340)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [
                        .clear,
                        Color(red: 0.04, green: 0.08, blue: 0.12).opacity(0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SignInHeader: View {
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.musicRed,
                                Color(red: 1.0, green: 0.42, blue: 0.34)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: Color.musicRed.opacity(0.24), radius: 22, y: 14)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("连接 Emby")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.primary)

                Text("登录后同步音乐资料库，并在本机保留缓存。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private enum SignInInputKind {
    case server
    case username
    case password
}

private struct SignInInputRow: View {
    let title: String
    let placeholder: String
    let icon: String
    let tint: Color
    let kind: SignInInputKind
    @Binding var text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                inputField
                    .font(.body.weight(.medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var inputField: some View {
        switch kind {
        case .server:
            TextField(placeholder, text: $text)
                .keyboardType(.URL)
                .submitLabel(.next)
        case .username:
            TextField(placeholder, text: $text)
                .textContentType(.username)
                .submitLabel(.next)
        case .password:
            SecureField(placeholder, text: $text)
                .textContentType(.password)
                .submitLabel(.done)
        }
    }
}
