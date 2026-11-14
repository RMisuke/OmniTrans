import SwiftUI
import Carbon
import os

// MARK: - Settings · 通用 Tab（自 SettingsPanelContent 拆分）

extension SettingsPanelContent {

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            animatedCard(icon: "paintpalette", title: "外观", index: 0) {
                HStack {
                    Text("主题模式").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { ThemeEngine.shared.mode },
                        set: { ThemeEngine.shared.setMode($0) }
                    )) {
                        ForEach(ThemeMode.allCases, id: \.self) { m in Text(m.displayName).tag(m) }
                    }.pickerStyle(.segmented).padding(.horizontal, 4).padding(.vertical, 2)
                }
            }
            animatedCard(icon: "macwindow", title: "窗口", index: 1) {
                VStack(spacing: 10) {
                    HStack {
                        Text("关闭方式").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $dismissMode) {
                            Text("点击框外").tag("clickOutside"); Text("手动关闭").tag("manual")
                        }.pickerStyle(.segmented).fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                    }
                    HStack {
                        Text("悬浮窗尺寸").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $panelSize) {
                            Text("小").tag("small"); Text("默认").tag("default")
                            Text("大").tag("large"); Text("动态").tag("dynamic")
                        }.pickerStyle(.segmented).fixedSize().padding(.horizontal, 4).padding(.vertical, 2)
                    }
                    HStack {
                        Text("动画效果").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: $animationsEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                }
            }
            animatedCard(icon: "clipboard", title: "剪贴板", index: 2) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用剪贴板监听", isOn: $clipboardMonitor)
                        .toggleStyle(.switch).controlSize(.small)
                        .onChange(of: clipboardMonitor) { _, on in
                            if on { ClipboardMonitor.shared.start() } else { ClipboardMonitor.shared.stop() }
                        }
                    Text("⚠️ 剪贴板监听仅在关闭全局快捷键时生效，否则快捷键会拦截复制操作。")
                        .font(.system(size: AppTheme.fontSizeFine)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            animatedCard(icon: "command", title: "快捷键", index: 3) {
                VStack(spacing: 12) {
                    animatedHotkeyRow("划词翻译", "hotkey") { c, m in
                        HotkeyManager.shared.reregister(carbonKey: c, carbonMods: m)
                    }
                    animatedHotkeyRow("OCR 翻译", "ocr_hotkey") { c, m in
                        HotkeyManager.shared.reregisterOCR(carbonKey: c, carbonMods: m)
                    }
                    animatedHotkeyRow("原位替换", "replace") { c, m in
                        HotkeyManager.shared.reregisterReplace(carbonKey: c, carbonMods: m)
                    }
                }
            }.id(refreshID)
            animatedCard(icon: "externaldrive.fill", title: "个人词典数据管理", index: 4) {
                VStack(spacing: 10) {
                    Button { exportDictionaryCSV() } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up").font(.system(size: AppTheme.fontSizeFine))
                            Text("导出个人词典 (CSV)").font(.system(size: AppTheme.fontSizeFine))
                            Spacer()
                        }
                    }.buttonStyle(.borderless)

                    Divider()

                    Button { importDictionaryCSV() } label: {
                        HStack {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: AppTheme.fontSizeFine))
                            Text("导入词典数据 (CSV)").font(.system(size: AppTheme.fontSizeFine))
                            Spacer()
                        }
                    }.buttonStyle(.borderless)

                    Divider()

                    Button { handleWipeTap() } label: {
                        Text(wipeButtonLabel).font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(wipeState == .ready ? .red : .secondary)
                    .disabled(wipeState == .counting)
                    .frame(width: 200)
                    if wipeState == .counting {
                        Text("此行为会彻底删除所有的个人词典缓存数据且不可恢复，请谨慎操作！")
                            .font(.system(size: AppTheme.fontSizeFine)).foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    var wipeButtonLabel: String {
        switch wipeState {
        case .idle:   return "清除全部个人词典数据"
        case .counting: return "确认删除 (\(wipeCountdown)s)"
        case .ready:  return "确认删除"
        }
    }

    func handleWipeTap() {
        switch wipeState {
        case .idle:
            wipeState = .counting; wipeCountdown = 10
            wipeTimer?.invalidate()
            wipeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    self.wipeCountdown -= 1
                    if self.wipeCountdown <= 0 {
                        self.wipeTimer?.invalidate()
                        self.wipeTimer = nil
                        self.wipeState = .ready
                    }
                }
            }
        case .ready:
            Task { await LocalDictionaryRepository.shared.deleteAll() }
            wipeState = .idle; wipeTimer?.invalidate(); wipeTimer = nil
        case .counting: break
        }
    }

    func importDictionaryCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let alert = NSAlert()
            alert.messageText = "导入冲突处理"
            alert.informativeText = "如果遇到本地已经缓存的相同词汇，是否用新导入的数据覆盖现有内容？"
            alert.addButton(withTitle: "覆盖"); alert.addButton(withTitle: "跳过")
            alert.alertStyle = .warning
            let overwrite = alert.runModal() == .alertFirstButtonReturn
            Task { await self.performCSVImport(url: url, overwrite: overwrite) }
        }
    }

    func performCSVImport(url: URL, overwrite: Bool) async {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").dropFirst()
        await LocalDictionaryRepository.shared.batchImport(lines: Array(lines), overwrite: overwrite)
    }

    func exportDictionaryCSV() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出词典数据"
        savePanel.nameFieldStringValue = "omnitrans_dictionary_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).csv"
        savePanel.allowedContentTypes = [.commaSeparatedText]

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            Task { await self.writeCSV(to: url) }
        }
    }

    func writeCSV(to url: URL) async {
        let rows = await LocalDictionaryRepository.shared.fetchAllForExport()
        var csv = "query_word,target_lang,model_name,json_data,updated_at\n"
        for row in rows {
            let escaped = row.jsonData.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(row.word)\",\"\(row.targetLang)\",\"\(row.modelName)\",\"\(escaped)\",\"\(row.timestamp)\"\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            os_log(.error, log: OSLog(subsystem: AppLogging.subsystem, category: "Settings"), "CSV export write failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Animated Hotkey Row

    func animatedHotkeyRow(_ label: String, _ key: String,
                           onSet: @escaping (Int, Int) -> Void) -> some View {
        let carbonKey = UserDefaults.standard.integer(forKey: "\(key)_carbonKey")
        let carbonMods = UserDefaults.standard.integer(forKey: "\(key)_carbonMods")
        let display = HotkeyManager.hotkeyLabelFrom(carbonKey: carbonKey, carbonMods: carbonMods)
        let isRecording = recordingKey == key

        return HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Spacer()

            // Key display with recording/completion animation
            if isRecording {
                recordingIndicator
            } else {
                Text(display)
                    .font(.system(size: AppTheme.fontSizeFine, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .transition(AppTheme.Motion.recordingComplete.asAsymmetricTransition(removal: AppTheme.Motion.recordingCancel, insertionOffset: 0, removalOffset: 0))
            }

            Button(isRecording ? "取消" : "录制") {
                if isRecording {
                    withAnimation(AppTheme.Motion.recordingCancel.resolveGated()) {
                        stopRecording()
                    }
                } else {
                    withAnimation(AppTheme.Motion.snip.resolveGated()) {
                        startRecording(for: key, onSet: onSet)
                    }
                }
            }
            .font(.system(size: AppTheme.fontSizeFine))
            .buttonStyle(PressableButtonStyle())
            .foregroundColor(isRecording ? .red : .accentColor)

            resetButton("默认", action: {
                let defKey: Int
                let defMod: Int
                if key == "hotkey" { defKey = Int(kVK_ANSI_D); defMod = Int(optionKey) }
                else if key == "ocr_hotkey" { defKey = Int(kVK_ANSI_F); defMod = Int(optionKey) }
                else { defKey = Int(kVK_ANSI_R); defMod = Int(optionKey) }
                UserDefaults.standard.set(defKey, forKey: "\(key)_carbonKey")
                UserDefaults.standard.set(defMod, forKey: "\(key)_carbonMods")
                onSet(defKey, defMod)
                withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) {
                    refreshID = UUID()
                }
            })
        }
        .animation(AppTheme.Motion.snip.resolveGated(), value: isRecording)
    }

    /// Breathing recording indicator.
    var recordingIndicator: some View {
        Text("按下组合键…")
            .font(.system(size: AppTheme.fontSizeFine))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(recordingKey != nil ? 1.03 : 1.0)
            .animation(
                AppTheme.Motion.recordingPulse.resolve()
                    .repeatForever(autoreverses: true),
                value: recordingKey
            )
    }

    // MARK: - Hotkey Recording

    func startRecording(for key: String, onSet: @escaping (Int, Int) -> Void) {
        // 先移除旧 monitor，防止换行录制时泄漏并吞掉全应用 keyDown（审计 H9）
        stopRecording()
        recordingKey = key
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.recordingKey == key else { return event }
            let carbonKey = Int(event.keyCode)
            let mods = HotkeyManager.carbonMods(from: event.modifierFlags)
            UserDefaults.standard.set(carbonKey, forKey: "\(key)_carbonKey")
            UserDefaults.standard.set(Int(mods), forKey: "\(key)_carbonMods")
            onSet(carbonKey, Int(mods))
            DispatchQueue.main.async {
                withAnimation(AppTheme.Motion.recordingComplete.resolveGated()) {
                    self.recordingKey = nil
                    self.refreshID = UUID()
                }
            }
            return nil
        }
    }

    func stopRecording() {
        recordingKey = nil
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }
}
