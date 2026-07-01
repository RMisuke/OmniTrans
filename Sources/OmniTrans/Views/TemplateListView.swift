import SwiftUI

struct TemplateListView: View {
    let onSelect: (ProviderTemplate) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择模板").font(.headline)
                Spacer()
                Button("取消") { onCancel() }.buttonStyle(.borderless)
            }.padding()

            Divider()

            ScrollView {
                ForEach(ProviderTemplate.ai) { t in
                    Button(action: { onSelect(t) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.body)
                                Text(t.desc).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(t.model)
                                .font(.caption2).foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary).cornerRadius(4)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if t.id != ProviderTemplate.ai.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }

                Divider().padding(.vertical, 8)
                Text("机器翻译").font(.subheadline).foregroundColor(.secondary).padding(.leading, 16)

                ForEach(ProviderTemplate.mt) { t in
                    Button(action: { onSelect(t) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.body)
                                Text(t.desc).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(t.model)
                                .font(.caption2).foregroundColor(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary).cornerRadius(4)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if t.id != ProviderTemplate.mt.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            Text("所有模板均使用标准协议").font(.caption2).foregroundColor(.secondary).padding(.vertical, 8)
        }
    }
}
