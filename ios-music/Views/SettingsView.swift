import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isSignOutConfirmationPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    preferencesCard
                    actionsCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [
                        Color.musicPageBackground,
                        Color.musicRed.opacity(0.06),
                        Color.musicPageBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
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

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: store.session == nil ? "wifi.slash" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(store.session == nil ? Color.secondary : Color.musicRed, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.session == nil ? "未连接" : "Emby 已连接")
                        .font(.title3.weight(.bold))
                    Text(store.session?.username ?? "登录后同步音乐资料库")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let session = store.session {
                VStack(spacing: 10) {
                    SettingsInfoRow(title: "服务器", value: session.serverURL.absoluteString)
                    SettingsInfoRow(title: "用户", value: session.username)
                    SettingsInfoRow(title: "状态", value: store.localizedLibraryStatus)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.musicSeparatorStroke, lineWidth: 0.8)
        }
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await store.refreshLibrary() }
            } label: {
                SettingsActionRow(title: "刷新资料库", subtitle: "重新拉取 Emby 音乐数据", icon: "arrow.clockwise", tint: .musicRed)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil || store.isLoading)

            Divider()
                .padding(.leading, 64)

            Button {
                store.clearCaches()
            } label: {
                SettingsActionRow(title: "清除缓存", subtitle: "删除本地资料库快照和封面缓存", icon: "trash", tint: .orange)
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.leading, 64)

            Button {
                isSignOutConfirmationPresented = true
            } label: {
                SettingsActionRow(title: "断开连接", subtitle: "退出当前 Emby 会话", icon: "rectangle.portrait.and.arrow.right", tint: .red)
            }
            .buttonStyle(.plain)
            .disabled(store.session == nil)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.musicSeparatorStroke, lineWidth: 0.8)
        }
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放与启动")
                .font(.system(size: 22, weight: .bold))

            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "淡入淡出",
                    subtitle: "播放、暂停和切歌时平滑过渡",
                    icon: "waveform",
                    isOn: $store.isPlaybackFadeEnabled
                )

                Divider()
                    .padding(.leading, 64)

                SettingsToggleRow(
                    title: "发现页作为首页",
                    subtitle: "下次打开应用时默认进入发现页",
                    icon: "safari",
                    isOn: $store.startsOnBrowse
                )

                Divider()
                    .padding(.leading, 64)

                SettingsToggleRow(
                    title: "播放页保持屏幕常亮",
                    subtitle: "展开播放页时不自动锁屏",
                    icon: "sun.max",
                    isOn: $store.keepsScreenAwakeOnPlayerPage
                )

                Divider()
                    .padding(.leading, 64)

                SettingsToggleRow(
                    title: "120Hz 高刷新率",
                    subtitle: "在支持 ProMotion 的设备上请求更高刷新率",
                    icon: "speedometer",
                    isOn: $store.prefersHighRefreshRate
                )
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.musicSeparatorStroke, lineWidth: 0.8)
            }
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.musicRed, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(.musicRed)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
