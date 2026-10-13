import Cocoa

extension SettingsWindowController {
    func buildPluginsPage() -> NSView {
        let heading = makeSectionHeading(L("plugins.title"))
        let intro = NSTextField(wrappingLabelWithString: L("plugins.intro"))
        intro.font = NSFont.appFont(.callout)
        intro.textColor = .secondaryLabelColor

        pluginSourceField = NSTextField()
        pluginSourceField.placeholderString = L("plugins.source")
        pluginSourceField.translatesAutoresizingMaskIntoConstraints = false
        pluginSourceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        let choose = NSButton(title: L("plugins.choose"), target: self, action: #selector(choosePluginFile))
        let inspect = NSButton(title: L("plugins.inspect"), target: self, action: #selector(inspectPluginSource))
        let sourceRow = NSStackView(views: [pluginSourceField, choose, inspect])
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = 8

        pluginPreviewLabel = NSTextField(wrappingLabelWithString: "")
        pluginPreviewLabel.font = NSFont.appFont(.subheadline)
        pluginPreviewLabel.textColor = .secondaryLabelColor
        pluginInstallButton = NSButton(title: L("plugins.install"), target: self,
                                       action: #selector(installPreviewedPlugin))
        pluginInstallButton.isEnabled = false

        pluginListStack = NSStackView()
        pluginListStack.orientation = .vertical
        pluginListStack.alignment = .leading
        pluginListStack.spacing = 18
        updatePluginsSection(force: true)

        let stack = NSStackView(views: [heading, intro, buildClaudeCodeBox(), sourceRow, pluginPreviewLabel,
                                        pluginInstallButton, pluginListStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    func updatePluginsSection(force: Bool = false) {
        guard pluginListStack != nil else { return }
        let records = DisplayPlugins.shared.records
        let hasLocation = DisplayPlugins.currentLocation() != nil
        let signature = "\(hasLocation)|" + records.keys.sorted().map { id in
            "\(id):\(records[id]?.info["version"] as? String ?? ""):"
                + "\(records[id]?.fetchedAt?.timeIntervalSince1970 ?? 0):\(records[id]?.error ?? "")"
        }.joined(separator: "|")
        guard force || signature != pluginsSignature else { return }
        pluginsSignature = signature
        pluginSettingsFields.removeAll()
        pluginListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if records.isEmpty {
            pluginListStack.addArrangedSubview(NSTextField(labelWithString: L("plugins.none")))
            return
        }
        for id in records.keys.sorted() {
            guard let record = records[id] else { continue }
            let info = record.info
            let name = DisplayPlugins.localized(info["name"] as? String ?? id, info: info)
            let version = info["version"] as? String ?? ""
            let title = makeSectionHeading("\(name)  \(version)")
            let origin = info["sourceOrigin"] as? String ?? "?"
            let author = info["author"] as? String ?? "?"
            var detailText = L("plugins.detail", id, author, origin)
            if record.requiresLocation {
                detailText += "\n" + L("plugins.location", origin)
                if !hasLocation { detailText += " " + L("plugins.location.missing") }
            }
            let detail = NSTextField(wrappingLabelWithString: detailText)
            detail.font = NSFont.appFont(.subheadline)
            detail.textColor = .secondaryLabelColor
            let attribution = DisplayPlugins.localized(info["attribution"] as? String ?? "", info: info)
            let credit = NSTextField(wrappingLabelWithString: attribution)
            credit.font = NSFont.appFont(.subheadline)
            credit.textColor = .secondaryLabelColor
            let statusText: String
            if let error = record.error {
                statusText = L("plugins.fetchError", error)
            } else if let fetched = record.fetchedAt {
                statusText = L("plugins.updated", DateFormatter.localizedString(
                    from: fetched, dateStyle: .short, timeStyle: .short))
            } else {
                statusText = L("plugins.waiting")
            }
            let status = NSTextField(labelWithString: statusText)
            status.font = NSFont.appFont(.subheadline)
            status.textColor = record.error == nil ? .secondaryLabelColor : .systemOrange
            var fields: [String: NSTextField] = [:]
            var rows: [NSView] = [title, detail, credit, status]
            for spec in info["settingsSpec"] as? [[String: Any]] ?? [] {
                guard let key = spec["key"] as? String else { continue }
                let label = DisplayPlugins.localized(spec["label"] as? String ?? key, info: info)
                let value = record.settings[key]
                let field = NSTextField(string: value.map { "\($0)" } ?? "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                rows.append(twoColumnRow(label, field))
                fields[key] = field
            }
            pluginSettingsFields[id] = fields
            let save = NSButton(title: L("plugins.save"), target: self,
                                action: #selector(savePluginSettings(_:)))
            save.identifier = NSUserInterfaceItemIdentifier(id)
            let remove = NSButton(title: L("plugins.remove"), target: self,
                                  action: #selector(removeInstalledPlugin(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(id)
            // Ohne eigene Einstellungen (etwa bei Plugins, die nur den Standort
            // des Displays nutzen) gibt es nichts zu speichern.
            let actions = NSStackView(views: fields.isEmpty ? [remove] : [save, remove])
            actions.orientation = .horizontal
            actions.spacing = 8
            rows.append(actions)
            let group = NSStackView(views: rows)
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 8
            pluginListStack.addArrangedSubview(group)
        }
    }

    @objc private func choosePluginFile() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedFileTypes = ["aimplugin"]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        pluginSourceField.stringValue = url.path
        inspectPluginSource()
    }

    @objc private func inspectPluginSource() {
        let source = pluginSourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pluginPreview = nil
        pluginInstallButton.isEnabled = false
        guard !source.isEmpty else { return }
        pluginPreviewLabel.stringValue = L("plugins.inspecting")
        DisplayPlugins.shared.inspect(source: source) { [weak self] result in
            guard let self = self, self.pluginSourceField.stringValue == source else { return }
            switch result {
            case .success(let info):
                self.pluginPreview = info
                let name = DisplayPlugins.localized(info["name"] as? String ?? "?", info: info)
                let author = info["author"] as? String ?? "?"
                let origin = info["sourceOrigin"] as? String ?? "?"
                let hash = info["sha256"] as? String ?? "?"
                var preview = L("plugins.preview", name, author, origin, String(hash.prefix(16)))
                if info["requiresLocation"] as? Bool == true {
                    preview += " " + L("plugins.location", origin)
                }
                self.pluginPreviewLabel.stringValue = preview
                self.pluginInstallButton.isEnabled = true
            case .failure(let error):
                self.pluginPreviewLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func installPreviewedPlugin() {
        guard let hash = pluginPreview?["sha256"] as? String else { return }
        let source = pluginSourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pluginInstallButton.isEnabled = false
        pluginPreviewLabel.stringValue = L("plugins.installing")
        DisplayPlugins.shared.install(source: source, expectedSHA256: hash) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let info):
                self.pluginPreview = nil
                self.pluginPreviewLabel.stringValue = L("plugins.installed", DisplayPlugins.localized(info["name"] as? String ?? "Plugin", info: info))
                self.updatePluginsSection(force: true)
                self.updateViewsSection(force: true)
            case .failure(let error):
                self.pluginPreviewLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func savePluginSettings(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let record = DisplayPlugins.shared.records[id],
              let fields = pluginSettingsFields[id] else { return }
        var values = record.settings
        for spec in record.info["settingsSpec"] as? [[String: Any]] ?? [] {
            guard let key = spec["key"] as? String, let field = fields[key] else { continue }
            if spec["kind"] as? String == "number" {
                guard let number = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) else {
                    pluginPreviewLabel.stringValue = L("plugins.invalidNumber", key)
                    return
                }
                values[key] = number
            } else {
                values[key] = field.stringValue
            }
        }
        do {
            try DisplayPlugins.shared.saveSettings(id: id, values: values)
            pluginPreviewLabel.stringValue = L("plugins.saved")
        } catch {
            pluginPreviewLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func removeInstalledPlugin(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = L("plugins.removeTitle")
        alert.informativeText = L("plugins.removeDetail", DisplayPlugins.shared.label(for: DisplayPlugins.prefix + id))
        alert.addButton(withTitle: L("plugins.remove"))
        alert.addButton(withTitle: L("plugins.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try DisplayPlugins.shared.remove(id: id)
            let views = Settings.shared.displayViews.map {
                $0 == DisplayPlugins.prefix + id ? Settings.clockView : $0
            }
            monitor?.updateDisplayViews(views)
            updatePluginsSection(force: true)
            updateViewsSection(force: true)
        } catch {
            pluginPreviewLabel.stringValue = error.localizedDescription
        }
    }

    // MARK: Claude Code (Issue #10)

    /// Eingebautes Fenster „Claude Code wartet“: Empfang, Hooks, wartende Sessions.
    private func buildClaudeCodeBox() -> NSView {
        let heading = makeSectionHeading(ClaudeCodeWindow.label)
        let intro = NSTextField(wrappingLabelWithString: L("cc.intro"))
        intro.font = NSFont.appFont(.subheadline)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 520

        claudeCodeListenerLabel = NSTextField(wrappingLabelWithString: "")
        claudeCodeListenerLabel.font = NSFont.appFont(.subheadline)
        claudeCodeHooksLabel = NSTextField(wrappingLabelWithString: "")
        claudeCodeHooksLabel.font = NSFont.appFont(.subheadline)
        claudeCodeHooksLabel.preferredMaxLayoutWidth = 520
        claudeCodeWaitingLabel = NSTextField(wrappingLabelWithString: "")
        claudeCodeWaitingLabel.font = NSFont.appFont(.subheadline)

        claudeCodeInstallButton = NSButton(title: L("cc.install"), target: self, action: #selector(installClaudeCodeHooks))
        claudeCodeRemoveButton = NSButton(title: L("cc.remove"), target: self, action: #selector(removeClaudeCodeHooks))
        let buttons = NSStackView(views: [claudeCodeInstallButton, claudeCodeRemoveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let hint = NSTextField(wrappingLabelWithString: L("cc.window.hint"))
        hint.font = NSFont.appFont(.subheadline)
        hint.textColor = .secondaryLabelColor

        ClaudeCodeWindow.shared.refreshHookStatus()
        updateClaudeCodeSection()
        let stack = NSStackView(views: [heading, intro, claudeCodeListenerLabel, claudeCodeHooksLabel,
                                        buttons, claudeCodeWaitingLabel, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    func updateClaudeCodeSection() {
        guard claudeCodeListenerLabel != nil else { return }
        let cc = ClaudeCodeWindow.shared
        switch cc.listenerState {
        case .running:
            claudeCodeListenerLabel.stringValue = L("cc.listener.running", Int(ClaudeCodeWindow.port))
            claudeCodeListenerLabel.textColor = .secondaryLabelColor
        case .starting:
            claudeCodeListenerLabel.stringValue = L("cc.listener.starting", Int(ClaudeCodeWindow.port))
            claudeCodeListenerLabel.textColor = .secondaryLabelColor
        case .failed(let message):
            claudeCodeListenerLabel.stringValue = L("cc.listener.failed", Int(ClaudeCodeWindow.port), message)
            claudeCodeListenerLabel.textColor = .systemRed
        }
        let hooks = cc.hookStatus ?? "missing"
        // Ereignisse kommen an, obwohl die Hooks nicht in dieser Datei stehen
        // (z. B. auf Projektebene): kein Grund zur Warnung.
        let elsewhere = hooks == "missing" && cc.receivingEvents(now: Date())
        claudeCodeHooksLabel.stringValue = L(elsewhere ? "cc.hooks.elsewhere" : "cc.hooks.\(hooks)")
            + " · " + ClaudeCodeWindow.settingsURL.path
        claudeCodeHooksLabel.textColor = hooks == "installed" || elsewhere ? .secondaryLabelColor : .systemOrange
        claudeCodeInstallButton.isHidden = hooks == "installed"
        claudeCodeRemoveButton.isHidden = hooks == "missing"

        let now = Date()
        let rows = cc.waiting(now: now).map { session -> String in
            let state = session.waiting == .permission ? "permission" : session.waiting == .input ? "input" : "done"
            let name = session.project.isEmpty ? ClaudeCodeWindow.label : session.project
            let minutes = Int(now.timeIntervalSince(session.since) / 60)
            return "\(name) · \(L("cc.state." + state)) · \(L("cc.minutes", minutes))"
        }
        claudeCodeWaitingLabel.stringValue = rows.isEmpty ? "" : L("cc.waiting") + "\n" + rows.joined(separator: "\n")
        claudeCodeWaitingLabel.isHidden = rows.isEmpty
    }

    @objc private func installClaudeCodeHooks() {
        confirmClaudeCodeHooks(install: true)
    }

    @objc private func removeClaudeCodeHooks() {
        confirmClaudeCodeHooks(install: false)
    }

    private func confirmClaudeCodeHooks(install: Bool) {
        let alert = NSAlert()
        alert.messageText = L(install ? "cc.install.title" : "cc.remove.title")
        alert.informativeText = L(install ? "cc.install.confirm" : "cc.remove.confirm",
                                  ClaudeCodeWindow.settingsURL.path)
        alert.addButton(withTitle: L(install ? "cc.install.ok" : "cc.remove.ok"))
        alert.addButton(withTitle: L("plugins.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        claudeCodeInstallButton.isEnabled = false
        claudeCodeRemoveButton.isEnabled = false
        ClaudeCodeWindow.shared.setHooks(install: install) { [weak self] error in
            guard let self = self else { return }
            self.claudeCodeInstallButton.isEnabled = true
            self.claudeCodeRemoveButton.isEnabled = true
            self.updateClaudeCodeSection()
            if let error {
                self.claudeCodeHooksLabel.stringValue = error.localizedDescription
                self.claudeCodeHooksLabel.textColor = .systemRed
            }
        }
    }
}
