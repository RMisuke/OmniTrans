import SwiftUI

/// API provider management: list, add, edit, delete, test, fetch models.
/// Supports drag-to-reorder which determines fallback priority order.
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
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundColor(.secondary)
                            Text("顺序决定失败降级时的调用优先级，使用 ↑↓ 调整").font(.caption2).foregroundColor(.secondary)
                        }.padding(.top, 4)

                        ForEach(Array(state.providers.enumerated()), id: \.element.id) { idx, provider in
                            HStack(alignment: .top, spacing: 4) {
                                // Reorder buttons
                                VStack(spacing: 2) {
                                    Button(action: { moveProvider(from: idx, to: idx - 1) }) {
                                        Image(systemName: "chevron.up")
                                            .font(.caption2).frame(width: 20, height: 18)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx == 0)
                                    .opacity(idx == 0 ? 0.2 : 1)

                                    Button(action: { moveProvider(from: idx, to: idx + 1) }) {
                                        Image(systemName: "chevron.down")
                                            .font(.caption2).frame(width: 20, height: 18)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx == state.providers.count - 1)
                                    .opacity(idx == state.providers.count - 1 ? 0.2 : 1)
                                }
                                .padding(.top, 6)

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
                }
                .padding()
            }

            // ── Template overlay ──
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

    private func moveProvider(from: Int, to: Int) {
        guard to >= 0, to < state.providers.count else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            state.providers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            state.save()
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
