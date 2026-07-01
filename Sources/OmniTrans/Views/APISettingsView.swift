import SwiftUI

/// API provider management: list, add, edit, delete, test, fetch models.
/// Shows ALL providers (including disabled ones) so users can re-enable them.
struct APISettingsView: View {
    @ObservedObject var state: AppState
    @State private var showTemplates = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("API 配置", systemImage: "server.rack")
                            .font(.headline)
                        Spacer()
                        Button(action: { showTemplates = true }) {
                            HStack(spacing: 4) { Image(systemName: "plus.circle"); Text("从模板添加") }
                                .font(.caption)
                        }.buttonStyle(.bordered).controlSize(.small)
                        Button(action: addBlank) {
                            HStack(spacing: 4) { Image(systemName: "plus"); Text("自定义") }
                                .font(.caption)
                        }.buttonStyle(.bordered).controlSize(.small)
                    }

                    if state.providers.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 32)).foregroundColor(.secondary)
                            Text("暂无 API 配置").font(.subheadline).foregroundColor(.secondary)
                            Text("点击上方按钮添加翻译 API").font(.caption).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        // Show ALL providers so disabled ones can be re-enabled
                        ForEach(state.providers) { provider in
                            ProviderCardView(
                                provider: provider,
                                allEnabled: state.enabledProviders,
                                onUpdate: { updated in
                                    state.updateProvider(updated)
                                },
                                onDelete: { deleted in
                                    state.deleteProvider(deleted)
                                },
                                onLoadKey: nil
                            )
                        }
                    }
                }
                .padding()
            }

            // ── Template overlay (inline, not sheet — avoids MenuBarExtra crash) ──
            if showTemplates {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showTemplates = false }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TemplateListView(
                        onSelect: { t in
                            addTemplate(t)
                            showTemplates = false
                        },
                        onCancel: {
                            showTemplates = false
                        }
                    )
                    .background(.regularMaterial)
                    .cornerRadius(12)
                    .shadow(radius: 12)
                    .frame(maxWidth: 420, maxHeight: 460)
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
    }

    private func addBlank() {
        let p = APIProvider.blank()
        state.addProvider(p)
    }

    private func addTemplate(_ t: ProviderTemplate) {
        var p = APIProvider.blank(kind: t.kind)
        p.name = t.name
        p.baseURL = t.baseURL
        p.modelName = t.model
        state.addProvider(p)
    }
}
