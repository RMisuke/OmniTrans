import SwiftUI

// MARK: - Settings · 翻译 Tab（自 SettingsPanelContent 拆分）

extension SettingsPanelContent {

    var translationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            animatedCard(icon: "globe", title: "翻译语言", index: 0) {
                HStack(spacing: 8) {
                    Text("源语言").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Picker("", selection: $state.sourceLang) {
                        ForEach(TranslationLanguage.allCases) { l in Text(l.rawValue).tag(l) }
                    }.pickerStyle(.menu).frame(width: 120)
                    Spacer()
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                        .rotationEffect(.degrees(state.sourceLang != .auto ? 0 : -10))
                        .animation(AppTheme.Motion.snip.resolveGated(), value: state.sourceLang)
                    Spacer()
                    Text("目标语言").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    Picker("", selection: $state.targetLang) {
                        ForEach(TranslationLanguage.allCases.filter { $0 != .auto }) { l in Text(l.rawValue).tag(l) }
                    }.pickerStyle(.menu).frame(width: 120)
                }
            }

            animatedCard(icon: "server.rack", title: "翻译服务", index: 1) {
                VStack(spacing: 10) {
                    providerRow(icon: "cpu", label: "翻译默认 API",
                                selection: Binding(get: { state.selectedProviderID }, set: { id in
                                    state.selectedProviderID = id; ProviderStorageManager.saveSelectedProviderID(id)
                                }))
                    Divider()
                    providerRow(icon: "character.book.closed", label: "词典默认 API",
                                selection: Binding(get: { state.dictProviderID }, set: { id in
                                    state.dictProviderID = id; ProviderStorageManager.saveDictProviderID(id)
                                }),
                                hasAutoOption: true)
                }
            }

            animatedCard(icon: "brain.head.profile", title: "语境感知", index: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用语境感知翻译", isOn: $isContextAware)
                        .toggleStyle(.switch).controlSize(.small)
                    if isContextAware {
                        contextIntensitySection
                            .transition(AppTheme.Motion.toggleReveal.asAsymmetricTransition(removal: AppTheme.Motion.toggleCollapse))
                    }
                }
            }

            animatedCard(icon: "clock.arrow.circlepath", title: "翻译历史", index: 3) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("最大保存条数").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                        Spacer()
                        TextField("", text: $maxHistoryText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onAppear {
                                // Sync text field with the actual stored value on every appear,
                                // so it never shows a stale hardcoded "100".
                                maxHistoryText = String(maxHistoryCount)
                            }
                            .onChange(of: maxHistoryText) { _, v in
                                // Only commit when the text is a valid positive integer;
                                // ignore empty / non-numeric input so we don't clobber the
                                // stored value with the fallback (100) while the user is editing.
                                guard let newValue = Int(v), newValue > 0 else { return }
                                if newValue != maxHistoryCount {
                                    maxHistoryCount = newValue
                                }
                            }
                    }
                    Toggle("禁用历史记录", isOn: $historyDisabled)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
            .onChange(of: maxHistoryCount) { _, _ in
                state.applyHistoryLimit()
            }

            animatedCard(icon: "cylinder.split.1x2.fill", title: "词典缓存", index: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用词典本地缓存", isOn: $dictCacheEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("关闭此开关后只会停止从本地缓存中查找数据，不会删除已保存的词典数据。")
                        .font(.system(size: AppTheme.fontSizeFine))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Advanced Options
            // v0.8：实底表面替代 `.regularMaterial`，阴影减淡。
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("高级选项", isOn: $showAdvanced)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("请充分了解参数后再操作，以免影响翻译质量")
                        .font(.system(size: AppTheme.fontSizeFine))
                        .foregroundColor(.secondary)
                }
                if showAdvanced {
                    advancedOptions
                        .transition(AppTheme.Motion.expandReveal.asAsymmetricTransition(removal: AppTheme.Motion.expandCollapse, insertionOffset: 8, removalOffset: -8))
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.MaterialPolicy.cardBackground,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.MaterialPolicy.cardStroke, lineWidth: 0.5))
            .opacity(cardsVisible ? 1 : 0)
            .offset(y: cardsVisible ? 0 : 8)
            .animation(AppTheme.Motion.panelOpen.resolveGated()?.delay(0.2), value: cardsVisible)
        }
    }

    // MARK: - Context Intensity

    var contextIntensitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上下文长度").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Slider(value: Binding(get: { Double(contextIntensity) },
                                      set: { newVal in
                    let rounded = Int(newVal.rounded())
                    if rounded != contextIntensity {
                        contextIntensity = rounded
                        sliderPulseTrigger = UUID()
                    }
                }), in: 0...4, step: 1).controlSize(.small)
                Text(contextSliders[contextIntensity].0)
                    .font(.system(size: AppTheme.fontSizeFine, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .modifier(ValuePulseModifier(trigger: sliderPulseTrigger))
            }
            Text(contextSliders[contextIntensity].1)
                .font(.system(size: AppTheme.fontSizeFine))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id("ctx-desc-\(contextIntensity)")
                .transition(AppTheme.Motion.sliderTextCrossfade.asTransition(offset: 0))
                .animation(AppTheme.Motion.sliderTextCrossfade.resolveGated(), value: contextIntensity)
        }
    }

    // MARK: - Provider Row Helper

    func providerRow(icon: String, label: String,
                     selection: Binding<UUID?>, hasAutoOption: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(.accentColor).frame(width: 18)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Picker("", selection: selection) {
                if hasAutoOption {
                    Text("跟随翻译 API").tag(nil as UUID?)
                }
                ForEach(state.enabledProviders) { p in
                    Text("\(p.name) · \(p.modelName)").tag(p.id as UUID?)
                }
            }.pickerStyle(.menu).frame(width: 240)
        }
    }

    // MARK: - Advanced Options

    var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            advRow("温度", tip: "控制生成文本的随机性。值越低输出越确定一致（适合代码/术语），值越高回复越多样（适合创意翻译）。范围 0~2，推荐 0.3。") {
                VStack(spacing: 8) {
                    HStack {
                        Slider(value: Binding(get: { translationTemp }, set: { newVal in
                            let snapped = (newVal * 20).rounded() / 20  // snap to 0.05
                            if abs(snapped - translationTemp) > 0.001 {
                                translationTemp = snapped
                                tempPulseTrigger = UUID()
                            }
                        }), in: 0.0...2.0, step: 0.05).controlSize(.small)
                        Text(String(format: "%.2f", translationTemp))
                            .font(.system(size: AppTheme.fontSizeFine, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .frame(width: 36)
                            .modifier(ValuePulseModifier(trigger: tempPulseTrigger))
                        resetButton("默认", action: { withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { translationTemp = 0.3 } })
                    }
                    HStack(spacing: 6) {
                        temperaturePreset("精确", 0.1)
                        temperaturePreset("均衡", 0.7)
                        temperaturePreset("创意", 1.0)
                    }
                }
            }
            advRow("最大 Token", tip: "限制 AI 单次回复的最大长度。值越小响应越快、费用越低；值越大可处理更长的翻译结果。短文本推荐 1024，长文推荐 4096。") {
                HStack {
                    TextField("", value: $translationMaxTokens, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80).font(.system(size: AppTheme.fontSizeFine))
                        .onChange(of: translationMaxTokens) { _, newValue in
                            if newValue < 1 { translationMaxTokens = 1 }
                        }
                    Stepper("", value: $translationMaxTokens, in: 1...16384, step: 256).labelsHidden()
                    resetButton("默认", action: { withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { translationMaxTokens = 1024 } })
                }
            }
            advRow("翻译缓存", tip: "关闭翻译缓存会增加重复划词翻译的 API 消耗和响应时间。默认建议保持开启。") {
                Toggle("启用翻译缓存", isOn: $cacheEnabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            advRow("自定义提示词", tip: "自定义发送给 AI 的系统指令。支持 {sourceLang} 和 {targetLang} 占位符，翻译时自动替换。") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用自定义提示词", isOn: $customPromptEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    TextEditor(text: Binding(
                        get: { customPromptText.isEmpty ? defaultPrompt : customPromptText },
                        set: { if customPromptEnabled { customPromptText = $0 } }
                    ))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .opacity(customPromptEnabled ? 1 : 0.4)
                    .disabled(!customPromptEnabled)
                    .animation(AppTheme.Motion.toggleReveal.resolveGated(), value: customPromptEnabled)
                    HStack {
                        Spacer()
                        resetButton("恢复默认", action: {
                            withAnimation(AppTheme.Motion.resetEmphasis.resolveGated()) { customPromptText = defaultPrompt }
                        })
                    }
                }
            }
        }
    }

    func temperaturePreset(_ label: String, _ value: Double) -> some View {
        let isActive = abs(translationTemp - value) < 0.05
        return Button {
            withAnimation(AppTheme.Motion.snip.resolveGated()) { translationTemp = value }
        } label: {
            Text(label)
                .font(.system(size: AppTheme.fontSizeMicro, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary))
                .foregroundColor(isActive ? .accentColor : .secondary)
                .clipShape(Capsule())
                .scaleEffect(isActive ? 1.05 : 1.0)
        }
        .buttonStyle(PressableButtonStyle())
        .animation(AppTheme.Motion.snip.resolveGated(), value: isActive)
    }

    func advRow(_ label: String, tip: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .help(tip)
                Spacer()
            }
            content()
        }
    }

    var defaultPrompt: String {
        "You are a professional translator. Translate the following text to {targetLang} accurately and concisely."
    }
}
