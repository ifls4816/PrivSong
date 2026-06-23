import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isSignOutConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Emby") {
                    connectionRows
                }

                Section("播放与启动") {
                    playbackRows
                }

                Section("资料库") {
                    libraryRows
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
            .confirmationDialog("断开 Emby 连接？", isPresented: $isSignOutConfirmationPresented, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) {
                    store.signOut()
                }

                Button("取消", role: .cancel) {}
            } message: {
                Text("断开后会清除本地资料库快照和封面缓存，需要重新连接 Emby。")
            }
        }
    }

    private var connectionRows: some View {
        Group {
            SettingsValueRow(
                title: store.session == nil ? "未连接" : "Emby 已连接",
                value: store.session?.username ?? "登录后同步音乐资料库",
                icon: store.session == nil ? "wifi.slash" : "externaldrive.connected.to.line.below",
                tint: store.session == nil ? .secondary : .musicRed,
                showsProgress: store.isLoading
            )
            if let session = store.session {
                SettingsInfoRow(title: "服务器", value: session.serverURL.absoluteString)
                SettingsInfoRow(title: "用户", value: session.username)
                SettingsInfoRow(title: "状态", value: store.localizedLibraryStatus)
            }
        }
    }

    private var libraryRows: some View {
        Group {
            Button {
                Task { await store.refreshLibrary() }
            } label: {
                SettingsActionRow(title: "刷新资料库", icon: "arrow.clockwise", tint: .musicRed, showsProgress: store.isLoading)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil || store.isLoading)

            Button {
                store.clearCaches()
            } label: {
                SettingsActionRow(title: "清除缓存", icon: "trash", tint: .orange)
            }
            .buttonStyle(.plain)

            Button {
                isSignOutConfirmationPresented = true
            } label: {
                SettingsActionRow(title: "断开连接", icon: "rectangle.portrait.and.arrow.right", tint: .red)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil)
        }
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
                title: "屏幕常亮",
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
    var showsProgress = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, tint: tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let icon: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(icon: icon, tint: tint)
            Text(title)
                .foregroundStyle(tint == .red ? Color.red : Color.primary)
            Spacer(minLength: 8)
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
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
